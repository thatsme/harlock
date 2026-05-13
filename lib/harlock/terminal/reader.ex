defmodule Harlock.Terminal.Reader do
  @moduledoc false
  # Reads bytes from /dev/tty, runs them through Input.Parser, and dispatches
  # events to the current subscriber.
  #
  # Raw fds in Erlang are bound to the opening process, so the actual
  # `:file.read/2` happens in a spawn_linked child process that opens its
  # own read fd. That sub-process can't share the main GenServer's mailbox,
  # so it forwards bytes via `{:bytes, binary}` messages.

  use GenServer
  require Logger

  alias Harlock.Terminal.Input.Parser
  alias Harlock.Terminal.Tty

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, subscriber), do: GenServer.call(server, {:subscribe, subscriber})

  @spec stop_reading(GenServer.server()) :: :ok
  def stop_reading(server), do: GenServer.call(server, :stop_reading)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    me = self()
    reader_pid = spawn_link(fn -> open_and_read(me) end)

    {:ok,
     %{
       caps: Keyword.fetch!(opts, :caps),
       reader_pid: reader_pid,
       parser: Parser.new(),
       subscriber: nil
     }}
  end

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscriber: subscriber}}
  end

  @impl true
  def handle_call(:stop_reading, _from, state) do
    if state.reader_pid && Process.alive?(state.reader_pid) do
      Process.unlink(state.reader_pid)
      Process.exit(state.reader_pid, :shutdown)
    end

    {:reply, :ok, %{state | reader_pid: nil}}
  end

  @impl true
  def handle_info({:bytes, bytes}, state) do
    {events, parser} = Parser.feed(state.parser, bytes)
    dispatch(events, state.subscriber)
    {:noreply, %{state | parser: parser}}
  end

  def handle_info({:EXIT, pid, reason}, %{reader_pid: pid} = state) do
    if reason not in [:normal, :shutdown] do
      Logger.warning("Harlock.Terminal.Reader read loop exited: #{inspect(reason)}")
    end

    {:noreply, %{state | reader_pid: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.reader_pid && Process.alive?(state.reader_pid) do
      Process.exit(state.reader_pid, :shutdown)
    end

    :ok
  end

  defp dispatch(_events, nil), do: :ok

  defp dispatch(events, subscriber) when is_pid(subscriber) do
    Enum.each(events, fn ev -> send(subscriber, {:harlock_event, ev}) end)
  end

  defp open_and_read(owner) do
    case Tty.open_read() do
      {:ok, fd} ->
        try do
          read_loop(fd, owner)
        after
          _ = Tty.close(fd)
        end

      {:error, reason} ->
        exit({:tty_open_failed, reason})
    end
  end

  defp read_loop(fd, owner) do
    case Tty.read(fd, 256) do
      {:ok, bytes} ->
        send(owner, {:bytes, bytes})
        read_loop(fd, owner)

      {:error, :eintr} ->
        read_loop(fd, owner)

      :eof ->
        :ok

      {:error, reason} ->
        Logger.error("Harlock.Terminal.Reader :file.read failed: #{inspect(reason)}")
        :ok
    end
  end
end
