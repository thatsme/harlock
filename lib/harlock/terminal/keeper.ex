defmodule Harlock.Terminal.Keeper do
  @moduledoc false
  # Manages termios state (raw mode + snapshot/restore) for the lifetime of
  # an app. Does NOT hold a /dev/tty fd — Writer and Reader open their own,
  # because raw fds in Erlang are bound to the opening process.
  #
  # This is still the load-bearing "terminal always restored" process: its
  # terminate/2 runs the stty restore even if every other child crashed,
  # because it is the first child in the supervision tree (= last to die).

  use GenServer

  alias Harlock.Terminal.Tty

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    case Tty.snapshot_termios() do
      {:ok, snap} ->
        :ok = Tty.set_raw_mode()
        {:ok, %{snapshot: snap}}

      {:error, reason} ->
        {:stop, {:tty_not_available, reason}}
    end
  end

  @impl true
  def terminate(_reason, %{snapshot: snap}) do
    Tty.restore_termios(snap)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
