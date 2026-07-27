# Run with:
#   ./scripts/run.sh explorer
#
# Or from iex:
#   iex -S mix
#   iex> c "examples/explorer.exs"
#   iex> Harlock.run(Explorer)
#
# The three widgets added in v0.5, in one app:
#
#   * tree     — collapsible, with one node (`deps`) whose children load
#                asynchronously through a Cmd rather than being known up front
#   * select   — dropdown filter; opens over the tree, and flips above the
#                control when it is near the bottom of the terminal
#   * menu     — vertical action list where moving the highlight and pressing
#                Enter are separate events
#
# Tab cycles focus between them. The focused widget owns its keys, so `update/2`
# has no per-key dispatch: each widget contributes one clause per message it can
# produce.

defmodule Explorer do
  use Harlock.App

  alias Harlock.Tree

  @filters [{:all, "All files"}, {:ex, "Elixir only"}, {:docs, "Docs only"}]

  @actions [{:expand_all, "Expand all"}, {:collapse_all, "Collapse all"}, {:quit, "Quit"}]

  def init(_) do
    %{
      nodes: nodes(),
      expanded: MapSet.new([:root]),
      node: :root,
      filter: :all,
      filter_highlight: :all,
      filter_open: false,
      action: :expand_all,
      status: "Right expands, Left collapses"
    }
  end

  # -- tree ------------------------------------------------------------------

  def update({:harlock_select, :files, id}, m), do: %{m | node: id}

  # Expanding `deps` is a side effect: nothing is loaded yet, so mark it in
  # flight and let the Cmd result arrive as an ordinary message. Everything
  # else is a plain set flip.
  def update({:harlock_toggle, :files, id}, m) do
    cond do
      MapSet.member?(m.expanded, id) ->
        %{m | expanded: MapSet.delete(m.expanded, id), status: "Collapsed #{id}"}

      Tree.children(find(m.nodes, id)) == :unloaded ->
        {
          %{
            m
            | expanded: MapSet.put(m.expanded, id),
              nodes: put_children(m.nodes, id, :loading),
              status: "Loading #{id}…"
          },
          Cmd.from(fn ->
            # Stands in for a filesystem walk or a call to a remote node.
            Process.sleep(400)
            {:loaded, id, fetched_deps()}
          end)
        }

      true ->
        %{m | expanded: MapSet.put(m.expanded, id), status: "Expanded #{id}"}
    end
  end

  def update({:loaded, id, children}, m) do
    %{m | nodes: put_children(m.nodes, id, children), status: "Loaded #{id}"}
  end

  def update({:harlock_submit, :files}, m), do: %{m | status: "Opened #{m.node}"}

  # -- select ----------------------------------------------------------------

  def update({:harlock_select, :filter, id}, m), do: %{m | filter_highlight: id}

  def update({:harlock_submit, :filter}, %{filter_open: false} = m),
    do: %{m | filter_open: true}

  def update({:harlock_submit, :filter}, %{filter_open: true} = m) do
    %{m | filter_open: false, filter: m.filter_highlight, status: "Filter: #{m.filter_highlight}"}
  end

  # -- menu ------------------------------------------------------------------

  def update({:harlock_select, :actions, id}, m), do: %{m | action: id}

  def update({:harlock_submit, :actions}, m), do: run_action(m.action, m)

  # -- raw keys --------------------------------------------------------------
  #
  # Escape is not routed: a widget that swallowed it would decide for the app
  # what cancelling means. This clause has to come before the quit clause, or an
  # open dropdown would exit the program.

  def update({:key, :escape, []}, %{filter_open: true} = m),
    do: %{m | filter_open: false, filter_highlight: m.filter}

  def update({:key, :escape, []}, _m), do: :quit

  def update(_event, m), do: m

  defp run_action(:quit, _m), do: :quit

  defp run_action(:expand_all, m) do
    %{m | expanded: MapSet.new(expandable_ids(m.nodes)), status: "Expanded all"}
  end

  defp run_action(:collapse_all, m) do
    %{m | expanded: MapSet.new(), status: "Collapsed all"}
  end

  # -- view ------------------------------------------------------------------

  def view(m) do
    vbox(
      constraints: [fill: 1, length: 1],
      children: [
        hbox(
          constraints: [fill: 2, fill: 1],
          children: [
            box(
              title: "Files",
              border: :rounded,
              padding: {0, 1},
              child:
                tree(
                  focusable: :files,
                  nodes: visible_nodes(m),
                  expanded: m.expanded,
                  focused: m.node
                )
            ),
            box(
              title: "Panel",
              border: :rounded,
              padding: {0, 1},
              child:
                vbox(
                  constraints: [length: 1, length: 1, length: 3, fill: 1],
                  children: [
                    select(
                      focusable: :filter,
                      items: @filters,
                      value: m.filter,
                      highlight: m.filter_highlight,
                      open: m.filter_open
                    ),
                    text(""),
                    menu(focusable: :actions, items: @actions, active: m.action),
                    spacer()
                  ]
                )
            )
          ]
        ),
        statusbar(left: m.status, right: "[Tab] focus  [Esc] quit")
      ]
    )
  end

  # -- model helpers ---------------------------------------------------------

  defp nodes do
    [
      %{
        id: :root,
        label: "my_app",
        children: [
          %{
            id: :lib,
            label: "lib",
            children: [
              %{id: :app_ex, label: "my_app.ex", children: []},
              %{id: :readme_md, label: "notes.md", children: []}
            ]
          },
          %{id: :readme, label: "README.md", children: []},
          # Nothing is known about this subtree until it is expanded.
          %{id: :deps, label: "deps", children: :unloaded}
        ]
      }
    ]
  end

  defp fetched_deps do
    [
      %{id: :telemetry, label: "telemetry", children: []},
      %{id: :ex_doc, label: "ex_doc", children: []}
    ]
  end

  # The filter rebuilds the node list rather than being pushed into the widget:
  # the tree renders what the model hands it, so filtering is the app's job.
  defp visible_nodes(%{filter: :all} = m), do: m.nodes
  defp visible_nodes(%{filter: filter} = m), do: reject_leaves(m.nodes, filter)

  # Filter the children first, then drop what is left empty. Doing it in this
  # order is what removes a directory whose matches were all filtered out —
  # filtering before recursing would leave it behind looking like a leaf.
  defp reject_leaves(nodes, filter) when is_list(nodes) do
    nodes
    |> Enum.map(fn node ->
      case Tree.children(node) do
        list when is_list(list) and list != [] ->
          %{node | children: reject_leaves(list, filter)}

        _leaf_or_lazy ->
          node
      end
    end)
    |> Enum.filter(fn node ->
      case Tree.children(node) do
        # Either a leaf that has to match, or a branch nothing survived in.
        [] -> keep_leaf?(node.label, filter)
        _kept -> true
      end
    end)
  end

  defp keep_leaf?(label, :ex), do: String.ends_with?(label, ".ex")
  defp keep_leaf?(label, :docs), do: String.ends_with?(label, ".md")

  defp find(nodes, id) do
    Enum.find_value(nodes, fn node ->
      cond do
        node.id == id -> node
        is_list(Tree.children(node)) -> find(Tree.children(node), id)
        true -> nil
      end
    end)
  end

  defp put_children(nodes, id, children) do
    Enum.map(nodes, fn
      %{id: ^id} = node ->
        %{node | children: children}

      node ->
        case Tree.children(node) do
          list when is_list(list) -> %{node | children: put_children(list, id, children)}
          _lazy -> node
        end
    end)
  end

  defp expandable_ids(nodes) do
    Enum.flat_map(nodes, fn node ->
      children = Tree.children(node)
      nested = if is_list(children), do: expandable_ids(children), else: []

      if Tree.expandable?(node), do: [node.id | nested], else: nested
    end)
  end
end

# If running via `mix run examples/explorer.exs` (rather than loading via iex),
# kick off the app immediately.
case System.argv() do
  ["--run"] -> Harlock.run(Explorer)
  _ -> :ok
end
