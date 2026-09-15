# Run with:
#   ./scripts/run.sh explorer
#
# or directly:
#   mix run examples/explorer.exs --run
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes.
#
# Three of the widgets for choosing among items, in one app:
#
#   * tree     — collapsible, with one node (`deps`) whose children load
#                asynchronously through a Cmd rather than being known up front
#   * select   — dropdown filter; opens over the actions, and flips above the
#                control when it is near the bottom of the terminal
#   * menu     — vertical action list where moving the highlight and pressing
#                Enter are separate events
#
# and around them:
#
#   * {:harlock_focus, from, to} — the dropdown closes when focus leaves it,
#                                  by Tab or by a click elsewhere
#   * mouse        — click a node to select it, its marker to expand it, the
#                    filter to open it and a choice to pick it, an action to run
#                    it; click a pane's border to focus what is inside
#   * box focus_proxy — each pane's border lights up while its widget has focus
#   * styled text  — the details pane and the status line
#
# Tab cycles focus between the widgets. The focused widget owns its keys, so
# `update/2` has no per-key dispatch: each widget contributes one clause per
# message it can produce.

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
      status: ["Right expands, Left collapses — or click the ", {"▸", bold: true}]
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
        %{m | expanded: MapSet.delete(m.expanded, id), status: ["Collapsed ", label(m, id)]}

      Tree.children(find(m.nodes, id)) == :unloaded ->
        {
          %{
            m
            | expanded: MapSet.put(m.expanded, id),
              nodes: put_children(m.nodes, id, :loading),
              status: [{"… ", fg: :yellow}, "Loading ", label(m, id)]
          },
          Cmd.from(fn ->
            # Stands in for a filesystem walk or a call to a remote node.
            Process.sleep(400)
            {:loaded, id, fetched_deps()}
          end)
        }

      true ->
        %{m | expanded: MapSet.put(m.expanded, id), status: ["Expanded ", label(m, id)]}
    end
  end

  def update({:loaded, id, children}, m) do
    m = %{m | nodes: put_children(m.nodes, id, children)}
    %{m | status: [{"✓ ", fg: :green}, "Loaded ", label(m, id)]}
  end

  def update({:harlock_submit, :files}, m), do: %{m | status: ["Opened ", label(m, m.node)]}

  # -- select ----------------------------------------------------------------

  def update({:harlock_select, :filter, id}, m), do: %{m | filter_highlight: id}

  def update({:harlock_submit, :filter}, %{filter_open: false} = m),
    do: %{m | filter_open: true}

  def update({:harlock_submit, :filter}, %{filter_open: true} = m) do
    %{
      m
      | filter_open: false,
        filter: m.filter_highlight,
        status: ["Filter: ", {filter_label(m.filter_highlight), bold: true}]
    }
  end

  # Tab, or a click anywhere else, moves focus off an open list without a key
  # the list sees. Closing here keeps it from staying drawn over the actions.
  def update({:harlock_focus, :filter, _to}, %{filter_open: true} = m),
    do: %{m | filter_open: false, filter_highlight: m.filter}

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
      constraints: [fill: 1, length: 1, length: 1],
      children: [
        hbox(
          constraints: [fill: 3, fill: 2],
          children: [
            pane(
              "Files",
              :files,
              tree(
                focusable: :files,
                nodes: visible_nodes(m),
                expanded: m.expanded,
                focused: m.node
              )
            ),
            vbox(
              constraints: [length: 3, length: 5, fill: 1],
              children: [
                pane(
                  "Filter",
                  :filter,
                  select(
                    focusable: :filter,
                    items: @filters,
                    value: m.filter,
                    highlight: m.filter_highlight,
                    open: m.filter_open
                  )
                ),
                pane(
                  "Actions",
                  :actions,
                  menu(focusable: :actions, items: @actions, active: m.action)
                ),
                box(
                  title: "Details",
                  border: :rounded,
                  border_style: %Style{fg: :bright_black},
                  padding: {0, 1},
                  child: details(m)
                )
              ]
            )
          ]
        ),
        text([" " | List.wrap(m.status)]),
        keybar(bindings: [{"Tab", "focus"}, {"Enter", "open / run"}, {"Esc", "quit"}])
      ]
    )
  end

  # A bordered pane in the theme's focus style while `id` has focus; a click on
  # its border focuses `id` too.
  defp pane(title, id, child) do
    box(title: title, border: :rounded, focus_proxy: id, padding: {0, 1}, child: child)
  end

  defp details(m) do
    node = find(m.nodes, m.node)
    key = &{String.pad_trailing(&1, 7), fg: :cyan}

    kind =
      case Tree.children(node) do
        [] -> "file"
        :unloaded -> [{"directory", bold: true}, {" (not loaded)", dim: true}]
        :loading -> [{"directory", bold: true}, {" (loading…)", fg: :yellow}]
        list -> [{"directory", bold: true}, ", #{length(list)} items"]
      end

    text(List.flatten([key.("Name"), {node.label, bold: true}, "\n", key.("Kind"), kind]))
  end

  # -- model helpers ---------------------------------------------------------

  defp label(m, id), do: {find(m.nodes, id).label, bold: true}

  defp filter_label(id), do: @filters |> List.keyfind(id, 0) |> elem(1)

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

  @doc false
  # The options `--run` starts the app with. The tests start it with these too,
  # so a test cannot pass on an option the real app never sets.
  def run_opts, do: [mouse: true]

  defp expandable_ids(nodes) do
    Enum.flat_map(nodes, fn node ->
      children = Tree.children(node)
      nested = if is_list(children), do: expandable_ids(children), else: []

      if Tree.expandable?(node), do: [node.id | nested], else: nested
    end)
  end
end

# `--run` starts the app; without it the file only defines the module, which is
# how the tests load it.
case System.argv() do
  ["--run"] -> Harlock.run(Explorer, nil, Explorer.run_opts())
  _ -> :ok
end
