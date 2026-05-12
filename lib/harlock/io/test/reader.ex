defmodule Harlock.IO.Test.Reader do
  @moduledoc false
  # In-memory reader for tests. Same message contract as Terminal.Reader
  # (`{:subscribe, pid}` and `:stop_reading` calls), but instead of reading
  # bytes from a tty, exposes an `inject/2` API that synthesizes events and
  # forwards them as `{:harlock_event, event}` to the current subscriber —
  # exactly the message shape the runtime expects.

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec inject(GenServer.server(), any()) :: :ok
  def inject(server, event), do: GenServer.call(server, {:inject, event})

  @impl true
  def init(_opts), do: {:ok, %{subscriber: nil}}

  @impl true
  def handle_call({:subscribe, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscriber: subscriber}}
  end

  def handle_call(:stop_reading, _from, state), do: {:reply, :ok, state}

  def handle_call({:inject, event}, _from, %{subscriber: subscriber} = state)
      when is_pid(subscriber) do
    send(subscriber, {:harlock_event, event})
    {:reply, :ok, state}
  end

  def handle_call({:inject, _event}, _from, state), do: {:reply, :ok, state}
end
