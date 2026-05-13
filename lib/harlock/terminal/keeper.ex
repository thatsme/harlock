defmodule Harlock.Terminal.Keeper do
  @moduledoc false
  # Manages termios state (raw mode + snapshot/restore) for the lifetime of
  # an app, and owns the SIGWINCH signal so terminal resizes reflow.
  #
  # Holds a Termios NIF fd (the control fd for tcgetattr/tcsetattr/TIOCGWINSZ).
  # Writer and Reader open their own /dev/tty fds for byte IO — they don't
  # share with us, because :file.open raw fds are process-bound. Termios
  # state is per-tty-device (not per-fd), so our raw-mode setting on the
  # control fd applies to their fds too.
  #
  # This is the load-bearing "terminal always restored" process: its
  # terminate/2 runs the tcsetattr restore even if every other child
  # crashed, because it is the first child in the supervision tree (= last
  # to die).
  #
  # SIGWINCH: :os.set_signal(:sigwinch, :handle) routes {:signal, :sigwinch}
  # messages to the most recent caller — this Keeper. On signal we read
  # TIOCGWINSZ via the NIF and forward {:harlock_resize, rows, cols} to
  # the runtime.

  use GenServer
  require Logger

  alias Harlock.Terminal.Termios

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Query the current terminal size via TIOCGWINSZ on the control fd.
  Returns `{:error, :no_tty}` if Keeper couldn't open /dev/tty (CI, piped
  stdin) so callers can fall back without crashing.
  """
  @spec size(GenServer.server()) ::
          {:ok, pos_integer(), pos_integer()} | {:error, term()}
  def size(server), do: GenServer.call(server, :size)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    runtime = Keyword.fetch!(opts, :runtime)

    case Termios.open() do
      {:ok, ctl} ->
        case Termios.get(ctl) do
          {:ok, snapshot} ->
            case Termios.set_raw(ctl) do
              :ok ->
                install_sigwinch()
                {:ok, %{ctl: ctl, snapshot: snapshot, runtime: runtime}}

              {:error, reason} ->
                Termios.close(ctl)
                {:stop, {:set_raw_failed, reason}}
            end

          {:error, reason} ->
            Termios.close(ctl)
            {:stop, {:snapshot_failed, reason}}
        end

      {:error, reason} ->
        # /dev/tty isn't usable. Fail loudly so the supervisor crashes the
        # whole tree BEFORE Writer enters alt-screen — that way the user
        # sees the error on their normal terminal instead of a frozen
        # broken UI they can't escape.
        IO.puts(
          :stderr,
          "\nHarlock: cannot open /dev/tty (#{inspect(reason)}). " <>
            "This usually means the BEAM was started without a controlling " <>
            "terminal (CI, piped stdin, etc.). Run interactively from a real shell.\n"
        )

        {:stop, {:tty_open_failed, reason}}
    end
  end

  @impl true
  def handle_call(:size, _from, %{ctl: nil} = state) do
    {:reply, {:error, :no_tty}, state}
  end

  def handle_call(:size, _from, %{ctl: ctl} = state) do
    {:reply, Termios.winsize(ctl), state}
  end

  @impl true
  def handle_info({:signal, :sigwinch}, %{ctl: nil} = state) do
    {:noreply, state}
  end

  def handle_info({:signal, :sigwinch}, %{ctl: ctl} = state) do
    case Termios.winsize(ctl) do
      {:ok, rows, cols} ->
        send(state.runtime, {:harlock_resize, rows, cols})

      {:error, reason} ->
        Logger.warning("Harlock SIGWINCH size query failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    uninstall_sigwinch()

    if state.snapshot && state.ctl do
      _ = Termios.set(state.ctl, state.snapshot)
    end

    if state.ctl do
      _ = Termios.close(state.ctl)
    end

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
