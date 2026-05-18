# Run with:
#   ./scripts/run.sh overview
# or:
#   mix run examples/overview.exs --run
#
# End-to-end example for the README: focus traversal (Tab/Shift-Tab),
# a focusable table with single-row selection, a focusable viewport
# scrolling via Harlock.Viewport.apply_key/4, and a Cmd round-trip.

defmodule Overview do
  use Harlock.App
  alias Harlock.{Cmd, Focus, Viewport}

  @log_visible 10

  def init(_) do
    %{
      tasks: [
        %{id: 1, name: "compile", state: "done"},
        %{id: 2, name: "test", state: "running"},
        %{id: 3, name: "dialyzer", state: "queued"},
        %{id: 4, name: "credo", state: "queued"},
        %{id: 5, name: "publish", state: "blocked"}
      ],
      selected: 1,
      log: for(i <- 1..40, do: "[#{i}] event line #{i}"),
      log_offset: 0
    }
  end

  def update({:key, {:char, ?q}, []}, _), do: :quit

  def update({:key, {:char, ?r}, []}, m) do
    cmd =
      Cmd.from(fn -> Enum.map(1..3, &"[refresh] new line #{&1}") end)
      |> Cmd.map(fn lines -> {:refreshed, lines} end)

    {m, cmd}
  end

  def update({:refreshed, lines}, m), do: %{m | log: lines ++ m.log}

  def update({:key, key, _} = ev, m) do
    case Focus.current() do
      :tasks ->
        update_tasks(ev, m)

      :log ->
        %{m | log_offset: Viewport.apply_key(m.log_offset, length(m.log), @log_visible, key)}

      _ ->
        m
    end
  end

  def update(_, m), do: m

  defp update_tasks({:key, :up, _}, m), do: %{m | selected: max(1, m.selected - 1)}

  defp update_tasks({:key, :down, _}, m),
    do: %{m | selected: min(length(m.tasks), m.selected + 1)}

  defp update_tasks(_, m), do: m

  def view(m) do
    vbox(
      constraints: [fill: 1, length: 1],
      children: [
        hbox(
          constraints: [percentage: 40, fill: 1],
          children: [
            box(
              title: "Tasks",
              border: :rounded,
              focusable: :tasks,
              child:
                table(
                  columns: [
                    column(title: "#", width: {:length, 3}, render: &Integer.to_string(&1.id)),
                    column(title: "name", width: {:fill, 1}, render: & &1.name),
                    column(title: "state", width: {:length, 8}, render: & &1.state)
                  ],
                  rows: m.tasks,
                  row_id: & &1.id,
                  selection: {:single, m.selected}
                )
            ),
            box(
              title: "Log",
              border: :rounded,
              focusable: :log,
              child:
                viewport(
                  offset: m.log_offset,
                  content_height: length(m.log),
                  child:
                    vbox(
                      constraints: List.duplicate({:length, 1}, length(m.log)),
                      children: Enum.map(m.log, &text/1)
                    )
                )
            )
          ]
        ),
        text("Tab focus  arrows/PgUp/PgDn scroll  r refresh  q quit", style: [dim: true])
      ]
    )
  end
end

case System.argv() do
  ["--run"] -> Harlock.run(Overview)
  _ -> :ok
end
