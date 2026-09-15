# Sysmon — a live BEAM process monitor built on Harlock.
#
# Run with:
#   ./scripts/run.sh sysmon
#
# or directly:
#   mix run examples/sysmon.exs --run
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes.
#
#   * table        — every process, refreshed on a timer; ↑↓ or j/k, a click,
#                    or the wheel move the cursor
#   * radio_group  — what the table is sorted by
#   * checkbox     — Live: untick it to stop the refresh while reading
#   * overlay      — help and quit confirmation, with buttons, trapping focus
#
# Keys:
#   ↑/↓ or j/k   move cursor (with the table focused; on the sort options the
#                arrows change the sort)
#   Tab          sort / Live / table
#   ?            help
#   q            quit (with confirm)
#   Esc          close a dialog

defmodule Sysmon do
  use Harlock.App

  @refresh_ms 1500

  @sorts [memory: "memory", reductions: "reductions", queue: "queue"]

  def init(_) do
    %{
      processes: [],
      cursor: nil,
      dialog: nil,
      sort: :memory,
      live: true
    }
    |> refresh()
  end

  # Unticking Live drops the interval, and the runtime stops it.
  def subs(%{live: true}), do: [Sub.interval(@refresh_ms, :refresh)]
  def subs(_model), do: []

  # ---- Events --------------------------------------------------------------

  def update(:refresh, m), do: refresh(m)

  def update({:key, {:char, ??}, []}, %{dialog: nil} = m), do: %{m | dialog: :help}
  def update({:key, :escape, []}, m), do: %{m | dialog: nil}

  def update({:harlock_submit, :help_close}, m), do: %{m | dialog: nil}

  def update({:key, {:char, ?q}, []}, %{dialog: nil} = m), do: %{m | dialog: :quit_confirm}
  def update({:key, {:char, ?y}, []}, %{dialog: :quit_confirm}), do: :quit
  def update({:key, {:char, ?n}, []}, %{dialog: :quit_confirm} = m), do: %{m | dialog: nil}

  # The dialog's buttons take Enter and Space when focused, and clicks.
  def update({:harlock_submit, :quit_yes}, _m), do: :quit
  def update({:harlock_submit, :quit_no}, m), do: %{m | dialog: nil}

  # ↑/↓, a click on a row and the wheel are routed by the table; j/k are not,
  # so they stay app-handled.
  def update({:harlock_select, :process_table, pid_str}, m), do: %{m | cursor: pid_str}
  def update({:key, {:char, ?j}, []}, %{dialog: nil} = m), do: move_cursor(m, 1)
  def update({:key, {:char, ?k}, []}, %{dialog: nil} = m), do: move_cursor(m, -1)

  def update({:harlock_select, :sort, sort}, m), do: refresh(%{m | sort: sort})
  def update({:harlock_toggle, :live, live}, m), do: %{m | live: live}

  def update(_, m), do: m

  # ---- View ----------------------------------------------------------------

  def view(m) do
    base =
      vbox(
        constraints: [length: 1, fill: 1, length: 1, length: 1],
        children: [
          text([
            {" Sysmon ", bold: true, reverse: true},
            "  ",
            {"#{length(m.processes)}", bold: true},
            " processes · sorted by ",
            {"#{m.sort}", fg: :cyan},
            " · ",
            if(m.live,
              do: {"refresh #{@refresh_ms}ms", fg: :green},
              else: {"paused", fg: :yellow, bold: true}
            )
          ]),
          process_table(m),
          controls(m),
          keybar(
            bindings: [{"↑↓ jk", "move"}, {"Tab", "controls"}, {??, "help"}, {?q, "quit"}],
            right: " up #{uptime()} "
          )
        ]
      )

    case m.dialog do
      nil ->
        base

      :help ->
        dialog(base, "Help", help_lines(), [{"Close", :help_close}], 10)

      :quit_confirm ->
        dialog(base, "Quit?", quit_lines(), [{"Quit", :quit_yes}, {"Cancel", :quit_no}], 7)
    end
  end

  defp process_table(m) do
    table(
      columns: [
        column(title: " PID", width: {:length, 13}, render: fn p -> p.pid_str end),
        column(
          title: "Name / initial call",
          width: {:fill, 2},
          render: fn p -> p.name end
        ),
        column(
          title: "Reds",
          width: {:length, 12},
          align: :right,
          render: fn p -> human_int(p.reductions) end
        ),
        column(
          title: "Mem",
          width: {:length, 10},
          align: :right,
          render: fn p -> human_bytes(p.memory) end
        ),
        column(
          title: "Q",
          width: {:length, 6},
          align: :right,
          render: fn p -> Integer.to_string(p.queue) end
        )
      ],
      rows: m.processes,
      row_id: & &1.pid_str,
      focused_row: m.cursor,
      focusable: :process_table
    )
  end

  # Below the table, so the table is first in Tab order and has focus at start.
  defp controls(m) do
    hbox(
      constraints: [length: 9, length: 42, fill: 1, length: 10],
      children: [
        text(" sort by", style: [dim: true]),
        radio_group(focusable: :sort, items: @sorts, value: m.sort, direction: :horizontal),
        spacer(),
        checkbox("Live", checked: m.live, focusable: :live)
      ]
    )
  end

  # A bordered panel over the table, trapping focus on its buttons. Keys still
  # work alongside them: Esc closes, y / n answer the quit question.
  defp dialog(base, title, lines, buttons, height) do
    button_row =
      hbox(
        constraints:
          Enum.map(buttons, fn {label, _} -> {:length, String.length(label) + 6} end) ++ [fill: 1],
        children:
          Enum.map(buttons, fn {label, id} -> button(label, focusable: id) end) ++ [spacer()]
      )

    overlay(
      child: base,
      over:
        box(
          title: " #{title} ",
          border: :double,
          border_style: [fg: :yellow],
          padding: {0, 1},
          child: vbox(constraints: [fill: 1, length: 1], children: [text(lines), button_row])
        ),
      width: 46,
      height: height,
      anchor: :center,
      focus_trap: true
    )
  end

  defp help_lines do
    key = &{String.pad_trailing(&1, 8), fg: :cyan}

    [
      key.("↑↓ jk"),
      "move the cursor\n",
      key.("click"),
      "select a row; the wheel moves too\n",
      key.("Tab"),
      "sort order, Live, the table\n",
      key.("?"),
      "this help\n",
      key.("q"),
      "quit, after confirming\n",
      key.("Esc"),
      "close a dialog"
    ]
  end

  defp quit_lines,
    do: ["Stop monitoring and exit?\n", {"y quits, n or Esc stays", dim: true}]

  # ---- Cursor + data -------------------------------------------------------

  defp refresh(m), do: ensure_cursor(%{m | processes: snapshot(m.sort)})

  defp ensure_cursor(%{processes: [], cursor: _} = m), do: %{m | cursor: nil}

  defp ensure_cursor(%{processes: ps, cursor: nil} = m),
    do: %{m | cursor: hd(ps).pid_str}

  defp ensure_cursor(%{processes: ps, cursor: c} = m) do
    if Enum.any?(ps, &(&1.pid_str == c)),
      do: m,
      else: %{m | cursor: hd(ps).pid_str}
  end

  defp move_cursor(%{processes: []} = m, _), do: m

  defp move_cursor(m, delta) do
    idx = Enum.find_index(m.processes, &(&1.pid_str == m.cursor)) || 0
    new_idx = max(0, min(length(m.processes) - 1, idx + delta))
    %{m | cursor: Enum.at(m.processes, new_idx).pid_str}
  end

  defp snapshot(sort) do
    Process.list()
    |> Enum.map(&info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&Map.fetch!(&1, sort), :desc)
  end

  defp info(pid) do
    case Process.info(pid, [
           :registered_name,
           :memory,
           :reductions,
           :message_queue_len,
           :initial_call
         ]) do
      nil ->
        nil

      info ->
        %{
          pid_str: :erlang.pid_to_list(pid) |> List.to_string(),
          name: name_for(info),
          memory: info[:memory] || 0,
          reductions: info[:reductions] || 0,
          queue: info[:message_queue_len] || 0
        }
    end
  end

  defp name_for(info) do
    case info[:registered_name] do
      [] -> initial_call_str(info[:initial_call])
      nil -> initial_call_str(info[:initial_call])
      name when is_atom(name) -> Atom.to_string(name)
    end
  end

  defp initial_call_str({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp initial_call_str(_), do: "(unknown)"

  # ---- Formatting ----------------------------------------------------------

  defp human_bytes(n) when n < 1024, do: "#{n} B"
  defp human_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp human_bytes(n) when n < 1024 * 1024 * 1024, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp human_bytes(n), do: "#{Float.round(n / 1_073_741_824, 1)} GB"

  defp human_int(n) when n < 1000, do: Integer.to_string(n)
  defp human_int(n) when n < 1_000_000, do: "#{Float.round(n / 1000, 1)}K"
  defp human_int(n) when n < 1_000_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp human_int(n), do: "#{Float.round(n / 1_000_000_000, 1)}G"

  defp uptime do
    {ms, _} = :erlang.statistics(:wall_clock)
    secs = div(ms, 1000)
    minutes = div(secs, 60)
    hours = div(minutes, 60)

    cond do
      hours > 0 -> "#{hours}h#{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m#{rem(secs, 60)}s"
      true -> "#{secs}s"
    end
  end

  @doc false
  # The options `--run` starts the app with. The tests start it with these too,
  # so a test cannot pass on an option the real app never sets.
  def run_opts, do: [mouse: true]
end

# `--run` starts the app; without it the file only defines the module, which is
# how the tests load it.
case System.argv() do
  ["--run"] -> Harlock.run(Sysmon, nil, Sysmon.run_opts())
  _ -> :ok
end
