# Sysmon — a live BEAM process monitor built on Harlock.
#
# Run with:
#   docker compose run --rm dev sh -c "elixir -r examples/sysmon.exs -S mix run -e 'Harlock.run(Sysmon)'"
#
# Or in IEx:
#   docker compose run --rm dev iex -S mix
#   iex> c "examples/sysmon.exs"
#   iex> Harlock.run(Sysmon)
#
# Keys:
#   ↑/↓ or j/k   move cursor
#   ?            help overlay
#   q            quit (with confirm)
#   Esc          close overlay

defmodule Sysmon do
  use Harlock.App

  @refresh_ms 1500

  def init(_) do
    %{
      processes: snapshot(),
      cursor: nil,
      dialog: nil
    }
    |> ensure_cursor()
  end

  def subs(_model), do: [Sub.interval(@refresh_ms, :refresh)]

  # ---- Events --------------------------------------------------------------

  def update(:refresh, m) do
    %{m | processes: snapshot()} |> ensure_cursor()
  end

  def update({:key, {:char, ??}, []}, m), do: %{m | dialog: :help}

  def update({:key, :escape, []}, m), do: %{m | dialog: nil}

  def update({:key, {:char, ?q}, []}, %{dialog: nil} = m), do: %{m | dialog: :quit_confirm}

  def update({:key, {:char, ?y}, []}, %{dialog: :quit_confirm}), do: :quit
  def update({:key, :enter, []}, %{dialog: :quit_confirm}), do: :quit

  def update({:key, {:char, ?n}, []}, %{dialog: :quit_confirm} = m), do: %{m | dialog: nil}

  def update({:key, :down, []}, m), do: move_cursor(m, 1)
  def update({:key, {:char, ?j}, []}, m), do: move_cursor(m, 1)
  def update({:key, :up, []}, m), do: move_cursor(m, -1)
  def update({:key, {:char, ?k}, []}, m), do: move_cursor(m, -1)

  def update(_, m), do: m

  # ---- View ----------------------------------------------------------------

  def view(m) do
    base =
      vbox(
        constraints: [length: 1, length: 1, fill: 1, length: 1],
        children: [
          text("Sysmon — BEAM process monitor", style: [bold: true]),
          text(
            "#{length(m.processes)} processes · refresh #{@refresh_ms}ms · " <>
              "?=help  q=quit  ↑↓/jk=move",
            style: [dim: true]
          ),
          process_table(m),
          status(m)
        ]
      )

    case m.dialog do
      nil -> base
      :help -> with_help(base)
      :quit_confirm -> with_quit_confirm(base)
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

  defp status(_m) do
    {total, _} = :erlang.statistics(:wall_clock)
    text("uptime: #{format_uptime(total)}", style: [dim: true])
  end

  defp with_help(base) do
    overlay(
      child: base,
      over:
        vbox(
          focus_trap: true,
          constraints: [length: 1, length: 1, length: 1, length: 1, length: 1, length: 1, fill: 1, length: 1],
          children: [
            text(" Help", style: [bold: true]),
            text(" ────"),
            text(" ?       toggle this help"),
            text(" q       quit (with confirm)"),
            text(" ↑↓ jk   move cursor"),
            text(" Esc     close overlay"),
            spacer(),
            text(" press Esc to close", style: [dim: true])
          ]
        ),
      width: 40,
      height: 10,
      anchor: :center,
      focus_trap: true
    )
  end

  defp with_quit_confirm(base) do
    overlay(
      child: base,
      over:
        vbox(
          focus_trap: true,
          constraints: [length: 1, length: 1, fill: 1, length: 1],
          children: [
            text(" Quit?", style: [bold: true]),
            text(" ─────"),
            text(" press y/Enter to quit, n/Esc to cancel"),
            spacer()
          ]
        ),
      width: 44,
      height: 6,
      anchor: :center,
      focus_trap: true
    )
  end

  # ---- Cursor + data -------------------------------------------------------

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

  defp snapshot do
    Process.list()
    |> Enum.map(&info/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory, :desc)
  end

  defp info(pid) do
    case Process.info(pid, [:registered_name, :memory, :reductions, :message_queue_len, :initial_call]) do
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

  defp format_uptime(ms) do
    secs = div(ms, 1000)
    minutes = div(secs, 60)
    hours = div(minutes, 60)

    cond do
      hours > 0 -> "#{hours}h#{rem(minutes, 60)}m"
      minutes > 0 -> "#{minutes}m#{rem(secs, 60)}s"
      true -> "#{secs}s"
    end
  end
end

case System.argv() do
  ["--run"] -> Harlock.run(Sysmon)
  _ -> :ok
end
