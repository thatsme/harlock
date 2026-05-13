defmodule Harlock.Terminal.Reader do
  @moduledoc false
  # Reads bytes from /dev/tty, runs them through Input.Parser, and dispatches
  # events to the current subscriber.
  #
  # No spawn_link child. /dev/tty access uses the termios NIF
  # (`Harlock.Terminal.Termios`) which calls `read(2)` directly: this works
  # from any process because it bypasses `:file.read`, which we proved
  # doesn't deliver bytes from spawned processes on macOS.
  #
  # Flow:
  #
  #   * `init/1` opens the Termios fd. Does NOT arm select yet — that
  #     happens on subscribe, which kills the "bytes arrive before
  #     subscriber wired" race.
  #   * `subscribe/2` records the subscriber pid and arms the first select.
  #   * `handle_info({:tty_ready, _})` reads non-blocking, parses, dispatches,
  #     and re-arms. EOF on the fd (ssh disconnect, etc.) is surfaced as
  #     `{:harlock_tty_lost, reason}` to the subscriber and the Reader
  #     terminates so the supervisor can tear down cleanly.
  #   * `terminate/2` closes the Termios fd. The NIF's stop callback
  #     handles the underlying `close(2)` after BEAM has unregistered the
  #     fd from its IO poller.

  use GenServer
  require Logger

  alias Harlock.Terminal.Input.Parser
  alias Harlock.Terminal.Termios

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok | {:error, term()}
  def subscribe(server, subscriber), do: GenServer.call(server, {:subscribe, subscriber})

  @spec stop_reading(GenServer.server()) :: :ok
  def stop_reading(server), do: GenServer.call(server, :stop_reading)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Termios.open() do
      {:ok, tty} ->
        {:ok,
         %{
           caps: Keyword.fetch!(opts, :caps),
           tty: tty,
           parser: Parser.new(),
           subscriber: nil
         }}

      {:error, reason} ->
        {:stop, {:tty_open_failed, reason}}
    end
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    case Termios.arm_select(state.tty) do
      :ok ->
        {:reply, :ok, %{state | subscriber: subscriber}}

      {:error, reason} = err ->
        Logger.warning("Harlock.Terminal.Reader arm_select failed: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  def handle_call(:stop_reading, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:tty_ready, tty}, %{tty: tty} = state) do
    case Termios.read_nonblock(tty, 256) do
      {:ok, bytes} ->
        {events, parser} = Parser.feed(state.parser, bytes)
        dispatch(events, state.subscriber)

        case Termios.arm_select(tty) do
          :ok ->
            {:noreply, %{state | parser: parser}}

          {:error, reason} ->
            Logger.warning("Harlock.Terminal.Reader re-arm failed: #{inspect(reason)}")
            {:stop, {:select_failed, reason}, %{state | parser: parser}}
        end

      :wouldblock ->
        # Spurious wakeup or another reader grabbed the bytes (shouldn't
        # happen with the owner check, but defensive). Re-arm and wait.
        case Termios.arm_select(tty) do
          :ok -> {:noreply, state}
          {:error, reason} -> {:stop, {:select_failed, reason}, state}
        end

      :eof ->
        notify_tty_lost(state, :eof)
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Harlock.Terminal.Reader read failed: #{inspect(reason)}")
        notify_tty_lost(state, reason)
        {:stop, {:read_failed, reason}, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.tty, do: Termios.close(state.tty)
    :ok
  end

  defp dispatch(_events, nil), do: :ok

  defp dispatch(events, subscriber) when is_pid(subscriber) do
    Enum.each(events, fn ev -> send(subscriber, {:harlock_event, ev}) end)
  end

  defp notify_tty_lost(%{subscriber: nil}, _reason), do: :ok

  defp notify_tty_lost(%{subscriber: subscriber}, reason) do
    send(subscriber, {:harlock_event, {:harlock_tty_lost, reason}})
  end
end
