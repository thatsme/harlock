# Run with:
#   ./scripts/run.sh dashboard
#
# or directly:
#   mix run examples/dashboard.exs --run
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes.
#
# The event-source seam, end to end:
#
#   * Sub.telemetry — watches [:demo, :job, :stop] and feeds a sparkline
#   * Sub.logger    — a :logger handler, so log calls become update/2 messages
#   * Sub.interval  — drives the fake workload
#
# and the controls around it:
#
#   * radio_group   — the workload's size, light / normal / heavy
#   * button        — pause and clear, by key or by click
#   * viewport      — the log history, newest first; the wheel scrolls it
#   * styled text   — the numbers in the stats line, and each log line's level
#
# A standalone example has no Ecto or Oban to listen to, so it emits its own
# events. That is not a shortcut: the work runs inside a Cmd, which means the
# telemetry handler fires in a *different process* from the UI, exactly as it
# would when the emitter is a real query or job. Point the same subscription at
# [:ecto, :repo, :query] and only its transform changes, to read Ecto's
# :total_time (native time units) instead of :duration.

defmodule Dashboard do
  use Harlock.App

  require Logger

  alias Harlock.Sub.Logger, as: LoggerSub

  # Bounded because both lists grow forever otherwise; the sparkline only ever
  # draws as many samples as it has columns.
  @history 120
  @log_history 200

  # Tuned against the normal workload so that its peaks trip it and its troughs
  # do not. Necessarily machine-dependent — on faster hardware nothing will be
  # "slow" and on slower hardware everything will be. The plumbing is the point,
  # not the number.
  @slow_us 4_500

  @loads [light: "light", normal: "normal", heavy: "heavy"]

  # `running: false` starts it paused, which is how the tests start it.
  def init(opts) do
    %{
      durations: [],
      logs: [],
      log_offset: 0,
      jobs: 0,
      slow: 0,
      tick: 0,
      load: :normal,
      running: Keyword.get(opts || [], :running, true)
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
    base = base_size(m.load)
    size = base + round(base * 5 / 6 * :math.sin(tick / 5))

    {%{m | tick: tick},
     Cmd.from(fn ->
       {micros, _sorted} =
         :timer.tc(fn -> Enum.sort(for _ <- 1..size, do: :rand.uniform(999)) end)

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
  #
  # The newest line goes on top. Someone scrolled down into the history is
  # reading an older line, so the offset moves with the insert and that line
  # stays where it was.
  def update({:log, entry}, m) do
    logs = Enum.take([{entry.level, LoggerSub.text(entry)} | m.logs], @log_history)
    offset = if m.log_offset > 0, do: min(m.log_offset + 1, length(logs) - 1), else: 0
    %{m | logs: logs, log_offset: offset}
  end

  # -- controls --------------------------------------------------------------

  def update({:harlock_scroll, :log, offset}, m), do: %{m | log_offset: offset}
  def update({:harlock_select, :load, load}, m), do: %{m | load: load}

  def update({:harlock_submit, :pause}, m), do: toggle_running(m)
  def update({:harlock_submit, :clear}, m), do: clear(m)

  def update({:key, {:char, ?p}, []}, m), do: toggle_running(m)
  def update({:key, {:char, ?c}, []}, m), do: clear(m)
  def update({:key, :escape, []}, _m), do: :quit
  def update(_event, m), do: m

  defp base_size(:light), do: 2_000
  defp base_size(:normal), do: 6_000
  defp base_size(:heavy), do: 12_000

  defp toggle_running(m), do: %{m | running: not m.running}
  defp clear(m), do: %{m | durations: [], logs: [], log_offset: 0, jobs: 0, slow: 0}

  # -- view ------------------------------------------------------------------

  def view(m) do
    vbox(
      constraints: [length: 3, length: 1, length: 1, fill: 1, length: 1],
      children: [
        box(
          title: "job duration (µs)",
          border: :rounded,
          border_style: [fg: :cyan],
          # Oldest first: the model prepends, so the list has to be reversed
          # for the newest sample to land at the right edge.
          child: sparkline(values: Enum.reverse(m.durations), style: [fg: :cyan])
        ),
        text([" " | stats(m)]),
        controls(m),
        log_pane(m),
        keybar(
          bindings: [
            {"Tab", "focus"},
            {"wheel", "scroll log"},
            {?p, "pause"},
            {?c, "clear"},
            {"Esc", "quit"}
          ],
          right: if(m.running, do: " running ", else: " paused ")
        )
      ]
    )
  end

  defp controls(m) do
    hbox(
      constraints: [length: 7, length: 36, fill: 1, length: 12, length: 10],
      children: [
        text(" load", style: [dim: true]),
        radio_group(focusable: :load, items: @loads, value: m.load, direction: :horizontal),
        spacer(),
        button(if(m.running, do: "Pause", else: "Resume"), focusable: :pause),
        button("Clear", focusable: :clear)
      ]
    )
  end

  defp log_pane(%{logs: []}) do
    box(
      title: "log",
      border: :rounded,
      padding: {0, 1},
      child: text("waiting for log lines…", style: [dim: true])
    )
  end

  defp log_pane(m) do
    box(
      title: "log · newest first · #{length(m.logs)} lines",
      border: :rounded,
      padding: {0, 1},
      focus_proxy: :log,
      child:
        viewport(
          focusable: :log,
          offset: m.log_offset,
          content_height: length(m.logs),
          scrollbar: true,
          child: text(Enum.flat_map(m.logs, &log_line/1))
        )
    )
  end

  defp log_line({level, line}),
    do: [{String.pad_trailing("#{level}", 8), level_style(level)}, line, "\n"]

  defp level_style(level) when level in [:emergency, :alert, :critical, :error],
    do: [fg: :red, bold: true]

  defp level_style(:warning), do: [fg: :yellow]
  defp level_style(:info), do: [fg: :green]
  defp level_style(_debug), do: [dim: true]

  # Aggregation is three lines of Enum in the model. Worth noting before
  # reaching for a windowed-aggregator abstraction: for counts and a mean over a
  # bounded list, there is nothing to abstract.
  defp stats(%{durations: []}), do: [{"no samples yet", dim: true}]

  defp stats(m) do
    last = hd(m.durations)
    mean = div(Enum.sum(m.durations), length(m.durations))

    [
      "jobs ",
      {"#{m.jobs}", bold: true},
      "   slow ",
      {"#{m.slow}", fg: if(m.slow > 0, do: :red, else: :green), bold: true},
      "   last ",
      {"#{last}µs", fg: if(last > @slow_us, do: :yellow, else: :cyan)},
      "   mean ",
      {"#{mean}µs", fg: :cyan},
      "   min ",
      {"#{Enum.min(m.durations)}µs", dim: true},
      "   max ",
      {"#{Enum.max(m.durations)}µs", dim: true}
    ]
  end

  @doc false
  # The options `--run` starts the app with. The tests start it with these too,
  # so a test cannot pass on an option the real app never sets.
  def run_opts, do: [mouse: true]
end

# `--run` starts the app; without it the file only defines the module, which is
# how the tests load it.
case System.argv() do
  ["--run"] -> Harlock.run(Dashboard, nil, Dashboard.run_opts())
  _ -> :ok
end
