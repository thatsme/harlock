defmodule Harlock.Terminal.Writer do
  @moduledoc false
  # Owns the write side of /dev/tty. Opens its own fd in init/1 (raw fds are
  # bound to the opening process). Writes ANSI enter on start and ANSI leave
  # on shutdown — the supervisor terminates children in reverse start order,
  # so this fires before Keeper's stty restore.

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

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Tty.open_write() do
      {:ok, fd} ->
        _ = Tty.write(fd, Ansi.enter())

        {:ok,
         %{
           fd: fd,
           caps: Keyword.fetch!(opts, :caps)
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

  @impl true
  def terminate(_reason, %{fd: fd}) do
    _ = Tty.write(fd, Ansi.leave())
    _ = Tty.close(fd)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
