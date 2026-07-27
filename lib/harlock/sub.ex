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

  alias Harlock.Sub.Logger, as: LoggerSub
  alias Harlock.Sub.Telemetry

  @type t ::
          {:interval, pos_integer(), any()}
          | {:telemetry, [[atom()]], function()}
          | {:logger, atom(), [atom()] | :all, function() | nil}
          | {:source, any(), (-> any()), (any() -> any()) | nil}

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

  ## Attachment happens on the first render

  `subs/1` is consulted while rendering, so a push-shaped subscription is not
  listening the instant `Harlock.run/2` is called — anything emitted before that
  first render is not delivered. This rarely matters for a dashboard watching a
  running system, but it does mean a test that emits immediately after starting
  an app is racing the attach, and it makes this the wrong tool for capturing
  events from an app's own startup. `interval/2` is unaffected: it starts its own
  clock rather than waiting on an external emitter.
  """
  @spec telemetry([atom()] | [[atom()]], function() | nil) :: t()
  def telemetry(events, transform \\ nil) do
    {:telemetry, normalize_events(events), transform}
  end

  # A single event name is a list of atoms; a list of names is a list of lists.
  defp normalize_events([head | _] = events) when is_list(head), do: events
  defp normalize_events(event) when is_list(event), do: [event]

  @doc """
  Subscribe to log events, delivering each one to `update/2`.

  Options:

    * `:level` — minimum level, filtered by `:logger` before Harlock sees it
      (default `:info`)
    * `:metadata` — metadata keys to keep, or `:all` (default `:all`)
    * `:transform` — turn an entry into the app's message; without one the app
      receives `{:log, entry}`

  An entry is `%{level: level, msg: raw_msg, meta: metadata}`. The message stays
  in Erlang's raw form; call `Harlock.Sub.Logger.text/1` in `update/2` to render
  it:

      def subs(_m), do: [Sub.logger(level: :warning)]

      def update({:log, entry}, m) do
        %{m | lines: [Harlock.Sub.Logger.text(entry) | m.lines]}
      end

  ## Do not log from `update/2`

  A `:logger` handler runs **inside the process that called `Logger.info/1`**.
  If handling a delivered log event causes another log call, that call is
  delivered too, and the app loops until something falls over. Erlang's own
  recursion guard does not help here, because the log originates in the runtime
  rather than inside the handler.

  The same reasoning bounds the rest: the handler must not block, since it
  stalls the caller, and it must not raise, since `:logger` removes a handler
  that does. So it builds one term and sends it — nothing else. Formatting is
  the app's job precisely because it allocates.

  Narrowing `:metadata` is worth doing on a busy system. Every entry is copied
  into the runtime's mailbox, and log metadata can carry stacktraces and large
  structs, so `metadata: [:module, :line, :request_id]` moves materially less
  than `:all`.

  Attachment timing matches `telemetry/2`: the handler is added on the first
  render, so logs emitted before that are not delivered.
  """
  @spec logger(keyword()) :: t()
  def logger(opts \\ []) do
    {
      :logger,
      Keyword.get(opts, :level, :info),
      Keyword.get(opts, :metadata, :all),
      Keyword.get(opts, :transform)
    }
  end

  @doc """
  Subscribe to anything that delivers Erlang messages.

  `subscribe` runs **inside** the subscription's own process and should register
  interest; every message that process then receives is forwarded to `update/2`,
  through `transform` if one is given. `key` identifies the subscription for
  diffing, so returning the same key twice starts one process.

  This is the generic form of the seam, and it is why Harlock ships no
  `Sub.pubsub`. Phoenix.PubSub delivers to whichever process called `subscribe`,
  which is precisely what this arranges:

      Sub.source({:pubsub, "orders"}, fn ->
        Phoenix.PubSub.subscribe(MyApp.PubSub, "orders")
      end)

  A named `Sub.pubsub` would mean a terminal UI library depending on a web
  framework's pubsub to deliver messages it already knows how to receive. The
  same shape covers a `:global` group, a registry, a `GenStage` consumer, or any
  library that sends to its subscriber — none of which Harlock needs to know
  about.

  ## What it does not do

  It has no lifecycle beyond the process. `subscribe` runs once on start, and the
  process is killed on stop, which unsubscribes anything scoped to a pid — true
  for Phoenix.PubSub and for monitors, not true for something requiring an
  explicit teardown call. Trap exits inside `subscribe` and clean up yourself if
  you need that, or use a purpose-built kind: `telemetry/2` and `logger/1` exist
  precisely because global registrations *do* need removing.

  Messages are forwarded as received. A source that sends high-frequency traffic
  will fill the runtime's mailbox as fast as it arrives — there is no buffering
  or sampling here, and adding some is the app's call.
  """
  @spec source(any(), (-> any()), (any() -> any()) | nil) :: t()
  def source(key, subscribe, transform \\ nil) when is_function(subscribe, 0) do
    {:source, key, subscribe, transform}
  end

  @doc false
  def start({:source, _key, subscribe, transform}, target) do
    spawn_link(fn ->
      subscribe.()
      forward_loop(target, transform)
    end)
  end

  def start({:interval, ms, msg}, target) do
    spawn_link(fn -> interval_loop(ms, msg, target) end)
  end

  def start({:telemetry, events, transform}, target) do
    Telemetry.start_link(events, transform, target)
  end

  def start({:logger, level, metadata, transform}, target) do
    LoggerSub.start_link(level, metadata, transform, target)
  end

  defp forward_loop(target, transform) do
    receive do
      message ->
        send(target, {:harlock_event, apply_transform(transform, message)})
        forward_loop(target, transform)
    end
  end

  defp apply_transform(nil, message), do: message
  defp apply_transform(fun, message) when is_function(fun, 1), do: fun.(message)

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
