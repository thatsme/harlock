defmodule Harlock.Terminal.Writer do
  @moduledoc false
  # Owns the write side of /dev/tty. Opens its own fd in init/1 (raw fds are
  # bound to the opening process). Writes ANSI enter on start and ANSI leave
  # on shutdown — the supervisor terminates children in reverse start order,
  # so this fires before Keeper's stty restore.
  #
  # `leave/1` and `enter/1` bracket handing the terminal to another program.
  # `entered` tracks which side of that the terminal is on, so shutdown during
  # a handover does not write the leave sequence a second time.

  use GenServer
  require Logger

  alias Harlock.Terminal.{Ansi, Tty}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec write(GenServer.server(), iodata()) :: :ok
  def write(server, data), do: GenServer.cast(server, {:write, data})

  @spec write_sync(GenServer.server(), iodata()) :: :ok | {:error, term()}
  def write_sync(server, data), do: GenServer.call(server, {:write, data})

  @doc "Leave the alternate screen and restore cursor and paste modes. Synchronous."
  @spec leave(GenServer.server()) :: :ok | {:error, term()}
  def leave(server), do: GenServer.call(server, :leave)

  @doc "Re-enter the alternate screen, cleared. Synchronous."
  @spec enter(GenServer.server()) :: :ok | {:error, term()}
  def enter(server), do: GenServer.call(server, :enter)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Tty.open_write() do
      {:ok, fd} ->
        mouse = Keyword.get(opts, :mouse, false)
        _ = Tty.write(fd, Ansi.enter(mouse: mouse))

        {:ok,
         %{
           fd: fd,
           caps: Keyword.fetch!(opts, :caps),
           mouse: mouse,
           entered: true
         }}

      {:error, reason} ->
        {:stop, {:tty_open_failed, reason}}
    end
  end

  @impl true
  def handle_cast({:write, data}, state) do
    case Tty.write(state.fd, data) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Harlock.Terminal.Writer write failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:write, data}, _from, state) do
    {:reply, Tty.write(state.fd, data), state}
  end

  def handle_call(:leave, _from, state),
    do: {:reply, Tty.write(state.fd, Ansi.leave()), %{state | entered: false}}

  def handle_call(:enter, _from, state),
    do: {:reply, Tty.write(state.fd, Ansi.enter(mouse: state.mouse)), %{state | entered: true}}

  @impl true
  def terminate(_reason, %{fd: fd} = state) do
    if state.entered, do: _ = Tty.write(fd, Ansi.leave())
    _ = Tty.close(fd)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
