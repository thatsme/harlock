defmodule Harlock.Sub do
  @moduledoc """
  Subscriptions — long-running sources of events that the runtime starts and
  stops as the model changes.

  An app declares its active subscriptions via the optional `subs/1`
  callback. The runtime diffs the returned list against what's currently
  running on each render: new entries get started, removed entries get
  stopped. The list is keyed by structural identity, so the same sub spec
  returned twice produces only one running process.

  v0.1 provides `Sub.interval/2`. Richer kinds (pubsub, file watchers,
  signal handlers, websockets) arrive alongside the full Cmd executor.
  """

  @type t :: {:interval, pos_integer(), any()}

  @doc """
  Send `msg` to the runtime every `ms` milliseconds. The first fire happens
  after `ms` ms, not immediately.
  """
  @spec interval(pos_integer(), any()) :: t()
  def interval(ms, msg) when is_integer(ms) and ms > 0 do
    {:interval, ms, msg}
  end

  @doc false
  def start({:interval, ms, msg}, target) do
    spawn_link(fn -> interval_loop(ms, msg, target) end)
  end

  defp interval_loop(ms, msg, target) do
    next = System.monotonic_time(:millisecond) + ms
    sleep_until(next)
    send(target, {:harlock_event, msg})
    interval_loop(ms, msg, target)
  end

  defp sleep_until(deadline) do
    now = System.monotonic_time(:millisecond)
    wait = max(0, deadline - now)
    if wait > 0, do: Process.sleep(wait)
  end
end
