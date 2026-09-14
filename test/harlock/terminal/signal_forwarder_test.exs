defmodule Harlock.Terminal.SignalForwarderTest do
  # Signal handling is global to the BEAM: erl_signal_server is one process,
  # and a signal sent to the OS pid reaches every handler on it.
  use ExUnit.Case, async: false

  alias Harlock.Terminal.SignalForwarder

  # These send a real SIGWINCH to this BEAM. That is the point: the resize
  # tests inject {:harlock_resize, ...} directly, which is how Keeper waiting
  # on a message OTP never sends went unnoticed.
  defp sigwinch_self do
    {_, 0} = System.cmd("kill", ["-WINCH", System.pid()])
    :ok
  end

  test "a real SIGWINCH reaches the installing process" do
    test_pid = self()
    :ok = SignalForwarder.install(test_pid, [:sigwinch])
    on_exit(fn -> SignalForwarder.uninstall(test_pid) end)

    sigwinch_self()

    assert_receive {:signal, :sigwinch}, 1_000
  end

  test "set_signal alone delivers nothing to the caller" do
    :ok = :os.set_signal(:sigwinch, :handle)

    sigwinch_self()

    refute_receive {:signal, :sigwinch}, 300
  end

  test "uninstall stops delivery without disabling the signal for other handlers" do
    parent = self()

    spawn_link(fn ->
      :ok = SignalForwarder.install(self(), [:sigwinch])
      send(parent, :installed)

      receive do
        {:signal, :sigwinch} -> send(parent, :other_received)
      end
    end)

    assert_receive :installed

    :ok = SignalForwarder.install(self(), [:sigwinch])
    :ok = SignalForwarder.uninstall(self())

    sigwinch_self()

    # Resetting SIGWINCH to :default on uninstall would starve the other
    # handler, as it would OTP's prim_tty_sighandler in a real shell.
    assert_receive :other_received, 1_000
    refute_receive {:signal, :sigwinch}, 300
  end

  test "the handler is removed when the installing process exits" do
    parent = self()

    pid =
      spawn(fn ->
        :ok = SignalForwarder.install(self(), [:sigwinch])
        send(parent, :installed)
      end)

    assert_receive :installed
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # erl_signal_server removes a supervised handler when it processes the
    # installer's exit, which can land after our :DOWN.
    assert wait_until(fn -> {SignalForwarder, pid} not in handlers() end)
  end

  test "signals that were not asked for are not forwarded" do
    assert {:ok, _} = SignalForwarder.handle_event(:sigcont, {self(), [:sigwinch]})
    refute_received {:signal, :sigcont}
  end

  defp handlers, do: :gen_event.which_handlers(:erl_signal_server)

  defp wait_until(fun, tries \\ 50)
  defp wait_until(fun, 0), do: fun.()

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      wait_until(fun, tries - 1)
    end
  end
end
