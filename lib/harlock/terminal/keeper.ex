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
  # SIGWINCH: OTP delivers handled signals to the erl_signal_server event
  # manager, not to the process that called :os.set_signal/2, so Keeper
  # installs a SignalForwarder handler there that sends it {:signal, :sigwinch}.
  # On signal we read TIOCGWINSZ via the NIF and forward
  # {:harlock_resize, rows, cols} to the runtime.
  #
  # exec/3 runs another program with the terminal, because Keeper owns the
  # control fd and the termios snapshot the program should start from. The
  # program becomes the terminal's foreground process group (see Termios and
  # c_src/README.md). When it ends Keeper takes the foreground back, puts the
  # terminal in raw mode again, re-reads the size — SIGWINCH went to the
  # program's group, not this BEAM, while it ran — and sends the runtime
  # {:harlock_resize, rows, cols} followed by {:harlock_exec_done, result}.
  # terminate/2 kills a program still running, so a crash cannot leave one
  # holding the terminal.

  use GenServer
  require Logger

  alias Harlock.Terminal.{SignalForwarder, Termios}

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

  @doc """
  Run `argv` in the terminal's foreground, with the terminal restored to the
  settings it had before the app started. Returns once the program is running;
  the result arrives at the runtime as `{:harlock_exec_done, result}`.

  The caller is responsible for leaving the alternate screen and pausing input
  first.
  """
  @spec exec(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def exec(server, argv, opts), do: GenServer.call(server, {:exec, argv, opts})

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
                {:ok, %{ctl: ctl, snapshot: snapshot, runtime: runtime, exec: nil}}

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

  def handle_call({:exec, _argv, _opts}, _from, %{exec: exec} = state) when exec != nil,
    do: {:reply, {:error, :busy}, state}

  def handle_call({:exec, argv, opts}, _from, %{ctl: ctl} = state) do
    # The program gets the terminal as the user's shell left it, not raw.
    _ = Termios.set(ctl, state.snapshot)

    with {:ok, exec, _os_pid} <- Termios.exec_start(ctl, argv, opts),
         :ok <- Termios.exec_arm(exec) do
      {:reply, :ok, %{state | exec: exec}}
    else
      {:error, reason} ->
        _ = Termios.set_raw(ctl)
        {:reply, {:error, reason}, state}
    end
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

  def handle_info({:exec_ready, exec}, %{exec: exec, ctl: ctl} = state) do
    case Termios.exec_read(exec) do
      :wouldblock ->
        _ = Termios.exec_arm(exec)
        {:noreply, state}

      result ->
        reclaim_terminal(ctl)

        case Termios.winsize(ctl) do
          {:ok, rows, cols} -> send(state.runtime, {:harlock_resize, rows, cols})
          {:error, _} -> :ok
        end

        send(state.runtime, {:harlock_exec_done, result})
        {:noreply, %{state | exec: nil}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    uninstall_sigwinch()

    # Before restoring termios: a program still in the foreground would keep
    # reading the terminal, and this BEAM could not reclaim it while it did.
    if state[:exec] do
      _ = Termios.exec_kill(state.exec)
      _ = Termios.reclaim_foreground(state.ctl)
    end

    if state.snapshot && state.ctl do
      _ = Termios.set(state.ctl, state.snapshot)
    end

    if state.ctl do
      _ = Termios.close(state.ctl)
    end

    :ok
  end

  # Back to how the app runs: this BEAM in the foreground, raw mode.
  defp reclaim_terminal(ctl) do
    case Termios.reclaim_foreground(ctl) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Harlock could not reclaim the terminal: #{inspect(reason)}")
    end

    _ = Termios.set_raw(ctl)
  end

  # A missing resize path degrades the app (no reflow) but must not stop it
  # from starting, so failures are logged rather than raised.
  defp install_sigwinch do
    case SignalForwarder.install(self(), [:sigwinch]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Harlock SIGWINCH handler not installed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("Harlock SIGWINCH handler not installed: #{Exception.message(e)}")
  catch
    _, _ -> :ok
  end

  defp uninstall_sigwinch do
    SignalForwarder.uninstall(self())
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
