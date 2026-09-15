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
  #
  # suspend/1 stops this BEAM for the shell's job control (Ctrl-Z, then fg).
  # The reply goes out before the stop: a caller still waiting in
  # GenServer.call when the VM stops would time out the moment it resumes,
  # because the call's timer keeps counting while stopped. SIGCONT on resume
  # arrives through the same SignalForwarder as SIGWINCH, and Keeper then
  # reclaims the terminal exactly as after exec/3, reporting
  # {:harlock_exec_done, :resumed}. If no stop happened — a check can pass and
  # the kernel still discard the signal — a watchdog reclaims the terminal
  # instead of leaving it released forever, reporting :not_stopped.
  #
  # A program started by exec/3 can be stopped too: Ctrl-Z in vim. The helper
  # reports it and leaves it stopped. With a job-control shell above this BEAM,
  # Keeper stops the BEAM as well, so the shell shows the job suspended as it
  # would have shown vim; on `fg` the SIGCONT arrives here, and Keeper gives the
  # terminal back to the program and resumes it. Without such a shell nothing
  # would resume a stopped BEAM, so the program is resumed at once, in place.

  use GenServer
  require Logger

  alias Harlock.Terminal.{LogBuffer, SignalForwarder, Termios}

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

  @doc """
  Whether suspending would work: this BEAM holds the terminal's foreground and
  a job-control shell is its parent, so the stop will be honoured and resumed.
  """
  @spec can_suspend?(GenServer.server()) :: boolean()
  def can_suspend?(server), do: GenServer.call(server, :can_suspend?)

  @doc """
  Restore the shell's terminal settings and stop this BEAM's process group.
  Returns before the stop; the runtime receives
  `{:harlock_exec_done, :resumed}` once the shell resumes it.

  The caller is responsible for leaving the alternate screen and pausing input
  first, and for checking `can_suspend?/1`.
  """
  @spec suspend(GenServer.server()) :: :ok | {:error, term()}
  def suspend(server), do: GenServer.call(server, :suspend)

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
                install_signals()

                {:ok,
                 %{
                   ctl: ctl,
                   snapshot: snapshot,
                   # Console logging would draw over the app; see LogBuffer.
                   log_capture: LogBuffer.capture(self()),
                   logs: LogBuffer.new(),
                   runtime: runtime,
                   exec: nil,
                   suspended: false,
                   exec_stopped: false
                 }}

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

  def handle_call(:can_suspend?, _from, %{ctl: ctl} = state),
    do: {:reply, Termios.job_control?(ctl) == true, state}

  def handle_call(:suspend, _from, %{exec: exec, suspended: suspended} = state)
      when exec != nil or suspended,
      do: {:reply, {:error, :busy}, state}

  def handle_call(:suspend, _from, %{ctl: ctl} = state) do
    _ = Termios.set(ctl, state.snapshot)
    send(self(), :stop_for_suspend)
    {:reply, :ok, %{state | suspended: true}}
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
  def handle_info(:stop_for_suspend, %{suspended: true} = state) do
    case Termios.suspend() do
      :ok ->
        # Runs after the resume if the stop happened, and ~1s from now if not.
        Process.send_after(self(), :suspend_watchdog, 1_000)
        {:noreply, state}

      {:error, _} ->
        {:noreply, resume_from_suspend(state, :not_stopped)}
    end
  end

  def handle_info({:signal, :sigcont}, %{suspended: true} = state),
    do: {:noreply, resume_from_suspend(state, :resumed)}

  # After a real stop both this and SIGCONT are overdue on resume, and this can
  # win the race; give SIGCONT a moment before deciding no stop happened.
  def handle_info(:suspend_watchdog, %{suspended: true} = state) do
    result =
      receive do
        {:signal, :sigcont} -> :resumed
      after
        200 -> :not_stopped
      end

    {:noreply, resume_from_suspend(state, result)}
  end

  # The program started by exec/3 stopped, and so did this BEAM, for the shell.
  def handle_info(:stop_with_program, %{exec_stopped: true} = state) do
    case Termios.suspend() do
      :ok ->
        Process.send_after(self(), :exec_stop_watchdog, 1_000)
        {:noreply, state}

      {:error, _} ->
        {:noreply, continue_program(state)}
    end
  end

  def handle_info({:signal, :sigcont}, %{exec_stopped: true} = state),
    do: {:noreply, continue_program(state)}

  # As for :suspend_watchdog: after a real stop this can arrive before SIGCONT.
  # Resuming the program is the right move either way.
  def handle_info(:exec_stop_watchdog, %{exec_stopped: true} = state) do
    receive do
      {:signal, :sigcont} -> :ok
    after
      200 -> :ok
    end

    {:noreply, continue_program(state)}
  end

  def handle_info({:signal, :sigcont}, state), do: {:noreply, state}
  def handle_info(:suspend_watchdog, state), do: {:noreply, state}
  def handle_info(:exec_stop_watchdog, state), do: {:noreply, state}

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

      {:stopped, _signal} ->
        if Termios.job_shell?() do
          send(self(), :stop_with_program)
          {:noreply, %{state | exec_stopped: true}}
        else
          {:noreply, continue_program(%{state | exec_stopped: true})}
        end

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

  def handle_info({:harlock_log, formatter, event}, state),
    do: {:noreply, %{state | logs: LogBuffer.push(state.logs, {formatter, event})}}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    uninstall_signals()

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

    # Last, on a terminal that is itself again: what was logged during the
    # session, including why it ended if it crashed.
    if state[:log_capture] do
      :ok = LogBuffer.release(state.log_capture)
      :ok = LogBuffer.replay(state.logs)
    end

    :ok
  end

  # Hand the terminal back to the stopped program, resume it, and wait for its
  # next report.
  defp continue_program(%{ctl: ctl, exec: exec} = state) do
    case Termios.exec_continue(ctl, exec) do
      :ok -> :ok
      {:error, reason} -> Logger.error("Harlock could not resume the program: #{inspect(reason)}")
    end

    _ = Termios.exec_arm(exec)
    %{state | exec_stopped: false}
  end

  defp resume_from_suspend(%{ctl: ctl} = state, result) do
    reclaim_terminal(ctl)

    case Termios.winsize(ctl) do
      {:ok, rows, cols} -> send(state.runtime, {:harlock_resize, rows, cols})
      {:error, _} -> :ok
    end

    send(state.runtime, {:harlock_exec_done, result})
    %{state | suspended: false}
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

  # A missing signal path degrades the app (no reflow, no resume after a
  # suspend) but must not stop it from starting, so failures are logged rather
  # than raised.
  defp install_signals do
    case SignalForwarder.install(self(), [:sigwinch, :sigcont]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Harlock signal handler not installed: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("Harlock signal handler not installed: #{Exception.message(e)}")
  catch
    _, _ -> :ok
  end

  defp uninstall_signals do
    SignalForwarder.uninstall(self())
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
