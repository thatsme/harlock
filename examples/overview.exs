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
  alias Harlock.Cmd

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

  # R2 auto-routing: when the focused viewport handles a scroll key, the
  # runtime computes the new offset and delivers this message. The app
  # only needs to write where the offset lives on the model.
  def update({:harlock_scroll, :log, new_offset}, m), do: %{m | log_offset: new_offset}

  # A focused table routes row movement the same way tabs and menu do. This
  # replaced a Focus.current() dispatch plus three clauses of index arithmetic.
  def update({:harlock_select, :tasks, id}, m), do: %{m | selected: id}

  def update(_, m), do: m

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
              border_style: [dim: true],
              focus_style: [fg: :cyan, bold: true],
              # :tasks lives on the table so the runtime can route row movement
              # to it; the box mirrors its focus for the border, the same
              # arrangement the Log box below uses for its viewport.
              focus_proxy: :tasks,
              child:
                table(
                  focusable: :tasks,
                  columns: [
                    column(title: "#", width: {:length, 3}, render: &Integer.to_string(&1.id)),
                    column(title: "name", width: {:fill, 1}, render: & &1.name),
                    column(title: "state", width: {:length, 8}, render: & &1.state)
                  ],
                  rows: m.tasks,
                  row_id: & &1.id,
                  focused_row: m.selected,
                  selection: {:single, m.selected}
                )
            ),
            box(
              title: "Log",
              border: :rounded,
              border_style: [dim: true],
              focus_style: [fg: :cyan, bold: true],
              # The :log id lives on the viewport inside, because that is what
              # has to receive the scroll keys. focus_proxy: lets the box light
              # up with it without joining focus traversal.
              focus_proxy: :log,
              child:
                viewport(
                  focusable: :log,
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
