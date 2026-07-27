defmodule Harlock.Tree do
  @moduledoc """
  Projection and key-event helpers for the `Harlock.Elements.tree/1` widget.

  The tree stays data. This module flattens it to the rows that are currently
  visible and maps keys onto that flat list, which is what keeps the renderer
  simple: it draws rows, and never walks a recursive structure.

  ## Nodes

  A node is a map with `:id` and `:label`, plus `:children`:

      %{id: :src, label: "src", children: [
        %{id: :main, label: "main.ex", children: []}
      ]}

  `:children` is either a list — `[]` for a leaf — or one of two lazy states:

    * `:unloaded` — expandable, contents not fetched yet
    * `:loading` — a fetch is in flight

  Lazy nodes are why this is worth modelling explicitly. A tree over a
  filesystem or a remote node cannot load eagerly, so expanding one is a side
  effect: the app receives `{:harlock_toggle, id, node_id}`, flips the node to
  `:loading`, returns a `Cmd`, and swaps in `{:loaded, children}` as a list when
  the result arrives. The widget renders each state without needing to know
  which one it is looking at.

  ## Expansion is keyed by id, never by index

  `expanded` is a `MapSet` (or list) of node ids. Indices would break the moment
  a node above collapsed: every key below it would shift by one, and the
  selection would jump to an unrelated row.

  ## Guides need the ancestor chain, not just a depth

  Each projected row carries `ancestors_last` — whether each ancestor was the
  last among its siblings — as well as its own `last_child?`. Depth alone is not
  enough: to know whether column 2 of a deeply nested row needs a `│`
  continuation or a blank, you have to know whether *that ancestor* had siblings
  still to come. The renderer cannot see siblings, so the projection computes
  it.
  """

  @type node_id :: any()
  @type children :: [tree_node()] | :unloaded | :loading
  @type tree_node :: %{
          :id => node_id(),
          :label => String.t(),
          optional(:children) => children()
        }

  @typedoc """
  One visible row. `ancestors_last` runs root-first and excludes the row
  itself; `parent` is `nil` at the top level.
  """
  @type row :: %{
          node: tree_node(),
          depth: non_neg_integer(),
          last_child?: boolean(),
          ancestors_last: [boolean()],
          parent: node_id() | nil
        }

  @type event :: {:select, node_id()} | {:toggle, node_id()} | :submit | :noop

  @doc """
  Flatten to the rows currently visible, depth-first.

  A node's children appear only when its id is in `expanded` *and* its children
  are a loaded list — an expanded `:unloaded` node contributes no rows until the
  app swaps the fetched children in.
  """
  @spec visible([tree_node()], Enumerable.t()) :: [row()]
  def visible(nodes, expanded) when is_list(nodes) do
    set = to_set(expanded)
    project(nodes, set, 0, [], nil)
  end

  defp project(nodes, set, depth, ancestors_last, parent) do
    last_index = length(nodes) - 1

    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, index} ->
      last? = index == last_index

      row = %{
        node: node,
        depth: depth,
        last_child?: last?,
        ancestors_last: ancestors_last,
        parent: parent
      }

      [row | child_rows(node, set, depth, ancestors_last ++ [last?], last?)]
    end)
  end

  defp child_rows(node, set, depth, ancestors_last, _last?) do
    if expanded?(node, set) do
      case children(node) do
        list when is_list(list) -> project(list, set, depth + 1, ancestors_last, node.id)
        _lazy -> []
      end
    else
      []
    end
  end

  @doc "A node's children, defaulting to a leaf when the key is absent."
  @spec children(tree_node()) :: children()
  def children(node), do: Map.get(node, :children, [])

  @doc """
  Whether a node can be expanded at all.

  Lazy nodes count even though nothing is loaded yet — that is the point of
  them. An empty loaded list does not: there is nothing to show.
  """
  @spec expandable?(tree_node()) :: boolean()
  def expandable?(node) do
    case children(node) do
      :unloaded -> true
      :loading -> true
      [] -> false
      list when is_list(list) -> true
    end
  end

  @doc "Whether a node is both expandable and currently expanded."
  @spec expanded?(tree_node(), Enumerable.t()) :: boolean()
  def expanded?(node, expanded) do
    expandable?(node) and node.id in to_set(expanded)
  end

  @doc """
  Map a `{:key, key, mods}` event onto a tree.

  `focused` is the id of the highlighted row.

    * `Up` / `Down` — move between visible rows, `{:select, id}`
    * `Home` / `End` — first / last visible row
    * `Right` — expand a collapsed node, or step into an already-expanded one
    * `Left` — collapse an expanded node, or step out to its parent
    * `Enter` — toggle an expandable node, `:submit` on a leaf
    * anything else — `:noop`

  Returning `{:toggle, id}` for `Right` on a collapsed node and `{:select, id}`
  when it is already open is what makes `Right` feel like one motion: press it
  repeatedly and you descend, rather than having to alternate keys.
  """
  @spec apply_key({:key, any(), [atom()]}, [tree_node()], Enumerable.t(), node_id()) :: event()
  def apply_key(event, nodes, expanded, focused) do
    rows = visible(nodes, expanded)
    set = to_set(expanded)
    apply_to_rows(event, rows, set, focused)
  end

  defp apply_to_rows(_event, [], _set, _focused), do: :noop

  defp apply_to_rows({:key, :down, _}, rows, _set, focused),
    do: step(rows, focused, +1)

  defp apply_to_rows({:key, :up, _}, rows, _set, focused),
    do: step(rows, focused, -1)

  defp apply_to_rows({:key, :home, _}, rows, _set, focused),
    do: jump(rows |> List.first() |> id_of(), focused)

  defp apply_to_rows({:key, :end, _}, rows, _set, focused),
    do: jump(rows |> List.last() |> id_of(), focused)

  defp apply_to_rows({:key, :right, _}, rows, set, focused) do
    case find_row(rows, focused) do
      nil ->
        :noop

      row ->
        cond do
          not expandable?(row.node) -> :noop
          not expanded?(row.node, set) -> {:toggle, row.node.id}
          true -> first_child(rows, row)
        end
    end
  end

  defp apply_to_rows({:key, :left, _}, rows, set, focused) do
    case find_row(rows, focused) do
      nil -> :noop
      %{node: node} = row -> if expanded?(node, set), do: {:toggle, node.id}, else: to_parent(row)
    end
  end

  defp apply_to_rows({:key, :enter, _}, rows, _set, focused) do
    case find_row(rows, focused) do
      nil -> :noop
      %{node: node} -> if expandable?(node), do: {:toggle, node.id}, else: :submit
    end
  end

  defp apply_to_rows(_event, _rows, _set, _focused), do: :noop

  # Movement clamps rather than wrapping. A tree is a hierarchy the user is
  # reading top-down, and jumping from the last leaf back to the root reads as
  # a glitch rather than a convenience — unlike a menu, where the list is short
  # and cyclic movement is the convention.
  defp step(rows, focused, delta) do
    ids = Enum.map(rows, & &1.node.id)

    case Enum.find_index(ids, &(&1 == focused)) do
      nil ->
        {:select, if(delta > 0, do: List.first(ids), else: List.last(ids))}

      index ->
        target = index + delta

        if target < 0 or target >= length(ids),
          do: :noop,
          else: {:select, Enum.at(ids, target)}
    end
  end

  defp jump(nil, _focused), do: :noop
  defp jump(target, focused) when target == focused, do: :noop
  defp jump(target, _focused), do: {:select, target}

  defp first_child(rows, row) do
    case Enum.find(rows, &(&1.parent == row.node.id)) do
      nil -> :noop
      child -> {:select, child.node.id}
    end
  end

  defp to_parent(%{parent: nil}), do: :noop
  defp to_parent(%{parent: parent}), do: {:select, parent}

  defp find_row(rows, focused), do: Enum.find(rows, &(&1.node.id == focused))

  defp id_of(nil), do: nil
  defp id_of(%{node: %{id: id}}), do: id

  defp to_set(%MapSet{} = set), do: set
  defp to_set(enumerable), do: MapSet.new(enumerable)
end
