defmodule Harlock.Sub do
  @moduledoc """
  Subscriptions — long-running sources of events that the runtime starts and
  stops as the model changes.

  An app declares its active subscriptions via the optional `subs/1`
  callback. The runtime diffs the returned list against what's currently
  running on each render: new entries get started, removed entries get
  stopped. The list is keyed by structural identity, so the same sub spec
  returned twice produces only one running process.

  ## Timers versus pushes

  `interval/2` is a *timer*: the runtime wakes itself up. `telemetry/2` is the
  other shape — an external source pushes, and the runtime receives without that
  source knowing anything about rendering. Both are subscriptions, and both are
  represented as a linked process whose lifetime *is* the subscription, which is
  what lets one diffing loop manage them without special cases.

  ## Specs are compared structurally

  The runtime keys running subscriptions by the spec term itself, so returning
  the same spec from `subs/1` twice starts one process, not two. A spec carrying
  a function is fine: a closure built at a fixed code location with equal
  captures compares equal across calls.

  It follows that a transform capturing something which *changes* every render —
  a value out of the model, say — produces a different spec each time, and the
  subscription is stopped and restarted on every frame. Capture only what is
  stable, and derive the rest inside `update/2`.
  """

  alias Harlock.Sub.Telemetry

  @type t ::
          {:interval, pos_integer(), any()}
          | {:telemetry, [[atom()]], function()}

  @doc """
  Send `msg` to the runtime every `ms` milliseconds. The first fire happens
  after `ms` ms, not immediately.
  """
  @spec interval(pos_integer(), any()) :: t()
  def interval(ms, msg) when is_integer(ms) and ms > 0 do
    {:interval, ms, msg}
  end

  @doc """
  Subscribe to `:telemetry` events and deliver each one to `update/2`.

  `events` is one event name (`[:ecto, :repo, :query]`) or a list of them. The
  transform turns an event into the message the app receives, and may take
  either the measurements alone or the full triple:

      Sub.telemetry([:ecto, :repo, :query], &{:query, &1.query_time})

      Sub.telemetry(
        [[:oban, :job, :stop], [:oban, :job, :exception]],
        fn event, _measurements, meta -> {:job, List.last(event), meta.worker} end
      )

  Omitting the transform delivers `{event, measurements, metadata}` unchanged.

  ## What this costs the system being measured

  A telemetry handler runs **inside whichever process emitted the event**, so
  the work done there is work stolen from the thing you are observing. The
  handler here does the minimum — apply the transform, send one message — and
  every aggregation happens on the runtime side. Keep transforms cheap for the
  same reason: a transform that formats a string or walks a list runs on the hot
  path of the emitter, not in your UI.

  Handlers are also global and are attached under an id derived from the events
  and the runtime pid, so two apps watching the same event do not unsubscribe
  each other. The subscription detaches when the runtime stops it or when the
  runtime dies, since the owning process is linked.
  """
  @spec telemetry([atom()] | [[atom()]], function() | nil) :: t()
  def telemetry(events, transform \\ nil) do
    {:telemetry, normalize_events(events), transform}
  end

  # A single event name is a list of atoms; a list of names is a list of lists.
  defp normalize_events([head | _] = events) when is_list(head), do: events
  defp normalize_events(event) when is_list(event), do: [event]

  @doc false
  def start({:interval, ms, msg}, target) do
    spawn_link(fn -> interval_loop(ms, msg, target) end)
  end

  def start({:telemetry, events, transform}, target) do
    Telemetry.start_link(events, transform, target)
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
