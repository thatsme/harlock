# Run with:
#   ./scripts/run.sh dashboard
#
# Or from iex:
#   iex -S mix
#   iex> c "examples/dashboard.exs"
#   iex> Harlock.run(Dashboard)
#
# The v0.6 event-source seam, end to end:
#
#   * Sub.telemetry — watches [:demo, :job, :stop] and feeds a sparkline
#   * Sub.logger    — a :logger handler, so log calls become update/2 messages
#   * Sub.interval  — drives the fake workload
#
# A standalone example has no Ecto or Oban to listen to, so it emits its own
# events. That is not a shortcut: the work runs inside a Cmd, which means the
# telemetry handler fires in a *different process* from the UI, exactly as it
# would when the emitter is a real query or job. Point the same subscription at
# [:ecto, :repo, :query] and nothing else here has to change.

defmodule Dashboard do
  use Harlock.App

  require Logger

  alias Harlock.Sub.Logger, as: LoggerSub

  # Bounded because both lists grow forever otherwise, and the sparkline only
  # ever draws as many samples as it has columns.
  @history 120
  @log_lines 8

  # Tuned against the workload below so that peaks trip it and the troughs do
  # not. Necessarily machine-dependent — on faster hardware nothing will be
  # "slow" and on slower hardware everything will be. The plumbing is the point,
  # not the number.
  @slow_us 4_500

  def init(_) do
    %{
      durations: [],
      logs: [],
      jobs: 0,
      slow: 0,
      tick: 0,
      running: true
    }
  end

  # Pausing removes the interval from the returned list, and the runtime stops
  # that subscription while leaving the other two alone. The telemetry and logger
  # subscriptions stay put, so a paused dashboard still shows anything the rest
  # of the system emits.
  def subs(%{running: false}), do: [log_sub(), telemetry_sub()]
  def subs(%{running: true}), do: [Sub.interval(150, :tick), log_sub(), telemetry_sub()]

  # Built at a fixed code location with no varying captures, so the spec compares
  # equal on every render and the subscription is not restarted each frame.
  defp telemetry_sub, do: Sub.telemetry([:demo, :job, :stop], &{:job, &1.duration})
  defp log_sub, do: Sub.logger(level: :info, metadata: [:pid])

  # -- the workload ----------------------------------------------------------

  def update(:tick, m) do
    tick = m.tick + 1

    # Real work, measured for real — but sized off the tick, and large enough
    # that the size drives the duration rather than timer noise. Too small and
    # the sparkline shows jitter instead of a shape.
    size = 6_000 + round(5_000 * :math.sin(tick / 5))

    {%{m | tick: tick},
     Cmd.from(fn ->
       {micros, _sorted} = :timer.tc(fn -> Enum.sort(for _ <- 1..size, do: :rand.uniform(999)) end)

       :telemetry.execute([:demo, :job, :stop], %{duration: micros}, %{size: size})

       # Logging from the Cmd is fine; it runs in a Task. Logging from update/2
       # would not be — a delivered log event handled by logging produces
       # another delivery, and it loops.
       #
       # An unconditional line every few jobs keeps the log pane demonstrating
       # something on any machine; a threshold alone would stay silent on a fast
       # one, which is how this example first shipped with a permanently empty
       # log box.
       if rem(tick, 6) == 0, do: Logger.info("job #{tick}: #{micros}µs over #{size} items")
       if micros > @slow_us, do: Logger.warning("slow job #{tick}: #{micros}µs")

       :job_done
     end)}
  end

  # -- the subscriptions -----------------------------------------------------

  def update({:job, duration}, m) do
    %{
      m
      | durations: Enum.take([duration | m.durations], @history),
        jobs: m.jobs + 1,
        slow: if(duration > @slow_us, do: m.slow + 1, else: m.slow)
    }
  end

  # Render the entry here rather than in the transform: a transform runs inside
  # the process that logged, so formatting there would bill that process for
  # this UI's work.
  def update({:log, entry}, m) do
    line = "[#{entry.level}] #{LoggerSub.text(entry)}"
    %{m | logs: Enum.take([line | m.logs], @log_lines)}
  end

  # -- keys ------------------------------------------------------------------

  def update({:key, {:char, ?p}, []}, m), do: %{m | running: not m.running}
  def update({:key, {:char, ?c}, []}, m), do: %{m | durations: [], logs: [], jobs: 0, slow: 0}
  def update({:key, :escape, []}, _m), do: :quit
  def update(_event, m), do: m

  # -- view ------------------------------------------------------------------

  def view(m) do
    vbox(
      constraints: [length: 3, length: 1, fill: 1, length: 1],
      children: [
        box(
          title: "job duration (µs)",
          border: :rounded,
          border_style: [fg: :cyan],
          child:
            # Oldest first: the model prepends, so the list has to be reversed
            # for the newest sample to land at the right edge.
            sparkline(values: Enum.reverse(m.durations), style: [fg: :cyan])
        ),
        text(stats(m), style: [fg: :cyan]),
        box(
          title: "log",
          border: :rounded,
          padding: {0, 1},
          child:
            vbox(
              constraints: List.duplicate({:length, 1}, @log_lines),
              children: Enum.map(log_rows(m), &text(&1, style: [dim: true]))
            )
        ),
        statusbar(
          left: if(m.running, do: "running", else: "paused"),
          right: "[p] pause  [c] clear  [Esc] quit"
        )
      ]
    )
  end

  # Aggregation is three lines of Enum in the model. Worth noting before
  # reaching for a windowed-aggregator abstraction: for counts and a mean over a
  # bounded list, there is nothing to abstract.
  defp stats(%{durations: []}), do: "no samples yet"

  defp stats(m) do
    n = length(m.durations)
    mean = div(Enum.sum(m.durations), n)

    "jobs #{m.jobs}   slow #{m.slow}   " <>
      "last #{hd(m.durations)}µs   mean #{mean}µs   " <>
      "min #{Enum.min(m.durations)}µs   max #{Enum.max(m.durations)}µs"
  end

  # Pad to a fixed height so the box does not reflow as lines arrive.
  defp log_rows(m) do
    m.logs ++ List.duplicate("", max(@log_lines - length(m.logs), 0))
  end
end

# If running via `mix run examples/dashboard.exs` (rather than loading via iex),
# kick off the app immediately.
case System.argv() do
  ["--run"] -> Harlock.run(Dashboard)
  _ -> :ok
end
