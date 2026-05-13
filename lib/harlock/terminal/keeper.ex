defmodule Harlock.Terminal.Keeper do
  @moduledoc false
  # Manages termios state (raw mode + snapshot/restore) for the lifetime of
  # an app, and owns the SIGWINCH signal so terminal resizes reflow.
  #
  # Does NOT hold a /dev/tty fd — Writer and Reader open their own, because
  # raw fds in Erlang are bound to the opening process.
  #
  # This is the load-bearing "terminal always restored" process: its
  # terminate/2 runs the stty restore even if every other child crashed,
  # because it is the first child in the supervision tree (= last to die).
  #
  # SIGWINCH: :os.set_signal(:sigwinch, :handle) installs a VM-wide handler
  # that sends {:signal, :sigwinch} to whichever process most recently
  # called it — i.e. this Keeper. On signal we shell out to `stty size`
  # (one syscall, ~3–5ms) and forward {:harlock_resize, rows, cols} to the
  # runtime. terminate/2 resets the handler so it isn't leaked past death.

  use GenServer
  require Logger

  alias Harlock.Terminal.Tty

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    runtime = Keyword.fetch!(opts, :runtime)

    case Tty.snapshot_termios() do
      {:ok, snap} ->
        :ok = Tty.set_raw_mode()
        install_sigwinch()
        {:ok, %{snapshot: snap, runtime: runtime}}

      {:error, reason} ->
        {:stop, {:tty_not_available, reason}}
    end
  end

  @impl true
  def handle_info({:signal, :sigwinch}, state) do
    case Tty.size() do
      {:ok, rows, cols} ->
        send(state.runtime, {:harlock_resize, rows, cols})

      {:error, reason} ->
        Logger.warning("Harlock SIGWINCH size query failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{snapshot: snap}) do
    uninstall_sigwinch()
    Tty.restore_termios(snap)
    :ok
  end

  def terminate(_reason, _state) do
    uninstall_sigwinch()
    :ok
  end

  defp install_sigwinch do
    :os.set_signal(:sigwinch, :handle)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp uninstall_sigwinch do
    :os.set_signal(:sigwinch, :default)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
