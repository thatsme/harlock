defmodule Harlock do
  @moduledoc """
  Harlock — a pure-Elixir TUI framework for Unix terminals.

  The two entry points:

    * `Harlock.run/2` — blocking. Starts the app, returns when it exits.
    * `Harlock.start_link/2` — non-blocking. Returns a supervisor pid for
      embedding inside an existing OTP application.

  v0.1 is under construction; the smoke functions are scaffold tooling.
  """

  alias Harlock.Terminal.{Ansi, Caps, Tty}
  _ = Caps

  @type app :: module()
  @type init_arg :: any()

  @doc """
  Start an app and block until it exits. Returns `{:ok, reason}` on normal
  exit, `{:error, reason}` if the supervisor failed to start.

  The caller's process is linked to the app supervisor, so killing the caller
  tears down the supervisor cleanly — which in turn restores the terminal.
  """
  @spec run(app(), init_arg()) :: {:ok, term()} | {:error, term()}
  def run(app, init_arg \\ nil) do
    caller = self()

    case Harlock.App.Supervisor.start_link(app: app, init_arg: init_arg, caller: caller) do
      {:ok, sup} ->
        ref = Process.monitor(sup)

        receive do
          {:harlock_done, reason} ->
            Supervisor.stop(sup, :normal)
            {:ok, reason}

          {:DOWN, ^ref, :process, ^sup, reason} ->
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Start an app under the caller's supervision tree without blocking.

  Returns `{:ok, sup_pid}`. The caller is responsible for handling the
  supervisor's lifecycle (linking, monitoring, stopping). Useful when
  embedding Harlock inside a larger OTP app — e.g. a Phoenix project with a
  dev-mode TUI dashboard.
  """
  @spec start_link(app(), init_arg()) :: Supervisor.on_start()
  def start_link(app, init_arg \\ nil) do
    Harlock.App.Supervisor.start_link(app: app, init_arg: init_arg, caller: self())
  end

  @doc """
  Round-trip smoke test. Opens /dev/tty, writes a greeting in the alt-screen,
  reads up to 5 bytes from the user, echoes what was typed, and restores the
  terminal. Should leave the terminal in a usable state after returning.
  """
  @spec smoke() :: binary() | {:error, term()}
  def smoke do
    Tty.with_raw(fn rfd, wfd ->
      :ok = Tty.write(wfd, [Ansi.move(1, 2), "Harlock smoke test."])
      :ok = Tty.write(wfd, [Ansi.move(3, 2), "Press 5 keys..."])
      bytes = read_n(rfd, 5, [])
      :ok = Tty.write(wfd, [Ansi.move(5, 2), "You typed: ", inspect(bytes)])
      Process.sleep(1200)
      bytes
    end)
  end

  @doc """
  Crash-path smoke test. Spawns a linked child that opens /dev/tty and then
  raises. `with_raw`'s nested `try/after` blocks restore the terminal before
  the process dies. Returns `{cleanup, reason}` where cleanup is `:ok` if
  the restore ran.
  """
  @spec smoke_crash() :: {:ok | :no_cleanup | term(), term()}
  def smoke_crash do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        try do
          Tty.with_raw(fn _rfd, wfd ->
            :ok = Tty.write(wfd, [Ansi.move(1, 2), "About to crash..."])
            Process.sleep(400)
            raise "intentional crash to verify terminal restoration"
          end)
        after
          send(parent, :cleanup_ran)
        end
      end)

    cleanup =
      receive do
        :cleanup_ran -> :ok
      after
        5_000 -> :no_cleanup
      end

    reason =
      receive do
        {:DOWN, ^ref, :process, ^pid, r} -> r
      after
        2_000 -> :no_exit
      end

    {cleanup, reason}
  end

  defp read_n(_fd, remaining, acc) when remaining <= 0 do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp read_n(fd, remaining, acc) do
    case Tty.read(fd, max(remaining, 16)) do
      {:ok, bytes} ->
        read_n(fd, remaining - byte_size(bytes), [bytes | acc])

      {:error, :eintr} ->
        read_n(fd, remaining, acc)

      :eof ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      {:error, _reason} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
