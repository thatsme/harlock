defmodule Harlock.TreeTest do
  use ExUnit.Case, async: true

  alias Harlock.Tree

  # a
  # ├── b
  # │   ├── d
  # │   └── e
  # └── c
  defp sample do
    [
      %{
        id: :a,
        label: "a",
        children: [
          %{
            id: :b,
            label: "b",
            children: [
              %{id: :d, label: "d", children: []},
              %{id: :e, label: "e", children: []}
            ]
          },
          %{id: :c, label: "c", children: []}
        ]
      }
    ]
  end

  defp ids(rows), do: Enum.map(rows, & &1.node.id)
  defp key(k), do: {:key, k, []}

  describe "visible/2" do
    test "a collapsed root shows only itself" do
      assert sample() |> Tree.visible([]) |> ids() == [:a]
    end

    test "expanding walks depth-first" do
      assert sample() |> Tree.visible([:a]) |> ids() == [:a, :b, :c]
      assert sample() |> Tree.visible([:a, :b]) |> ids() == [:a, :b, :d, :e, :c]
    end

    test "expanding a node whose parent is collapsed shows nothing extra" do
      # :b is expanded but unreachable — the projection is what is *visible*
      assert sample() |> Tree.visible([:b]) |> ids() == [:a]
    end

    test "accepts a MapSet or a list" do
      assert Tree.visible(sample(), MapSet.new([:a])) == Tree.visible(sample(), [:a])
    end

    test "depth and parent are recorded per row" do
      rows = Tree.visible(sample(), [:a, :b])

      assert Enum.map(rows, & &1.depth) == [0, 1, 2, 2, 1]
      assert Enum.map(rows, & &1.parent) == [nil, :a, :b, :b, :a]
    end

    test "last_child? marks the final sibling at each level" do
      rows = Tree.visible(sample(), [:a, :b])

      assert Enum.map(rows, & &1.last_child?) == [true, false, false, true, true]
    end

    test "ancestors_last carries the whole chain, not just a depth" do
      rows = Tree.visible(sample(), [:a, :b])
      by_id = Map.new(rows, &{&1.node.id, &1})

      assert by_id[:a].ancestors_last == []
      # :b's ancestor is :a, which is last at the root level
      assert by_id[:b].ancestors_last == [true]
      # :d's ancestors are :a (last) then :b (not last) — that second flag is
      # what tells the renderer to draw a continuation bar rather than a blank
      assert by_id[:d].ancestors_last == [true, false]
      assert by_id[:e].ancestors_last == [true, false]
    end

    test "an empty tree projects to nothing" do
      assert Tree.visible([], [:a]) == []
    end
  end

  describe "lazy children" do
    defp lazy(state), do: [%{id: :root, label: "root", children: state}]

    test "unloaded and loading nodes are expandable" do
      assert Tree.expandable?(hd(lazy(:unloaded)))
      assert Tree.expandable?(hd(lazy(:loading)))
    end

    test "an empty loaded list is a leaf" do
      refute Tree.expandable?(hd(lazy([])))
    end

    test "a node with no :children key at all is a leaf" do
      refute Tree.expandable?(%{id: :x, label: "x"})
      assert Tree.children(%{id: :x, label: "x"}) == []
    end

    test "expanding an unloaded node adds no rows until children arrive" do
      # this is the whole point of the lazy states: the app has flipped the
      # node open and fired a Cmd, but there is nothing to draw yet
      assert lazy(:unloaded) |> Tree.visible([:root]) |> ids() == [:root]
      assert lazy(:loading) |> Tree.visible([:root]) |> ids() == [:root]

      loaded = [%{id: :root, label: "root", children: [%{id: :kid, label: "kid", children: []}]}]
      assert loaded |> Tree.visible([:root]) |> ids() == [:root, :kid]
    end

    test "Right on an unloaded node toggles, so the app can start the fetch" do
      assert Tree.apply_key(key(:right), lazy(:unloaded), [], :root) == {:toggle, :root}
    end

    test "Right on a loading node that is already expanded cannot descend" do
      assert Tree.apply_key(key(:right), lazy(:loading), [:root], :root) == :noop
    end
  end

  describe "movement" do
    test "Down and Up walk visible rows across depths" do
      nodes = sample()
      assert Tree.apply_key(key(:down), nodes, [:a, :b], :b) == {:select, :d}
      assert Tree.apply_key(key(:up), nodes, [:a, :b], :d) == {:select, :b}
      # from the last child of :b straight to :a's next child
      assert Tree.apply_key(key(:down), nodes, [:a, :b], :e) == {:select, :c}
    end

    test "movement clamps instead of wrapping" do
      # a tree is read top-down; jumping from the last leaf to the root reads
      # as a glitch, unlike a menu where cyclic movement is conventional
      nodes = sample()
      assert Tree.apply_key(key(:up), nodes, [:a], :a) == :noop
      assert Tree.apply_key(key(:down), nodes, [:a], :c) == :noop
    end

    test "Home and End go to the first and last visible rows" do
      nodes = sample()
      assert Tree.apply_key(key(:home), nodes, [:a, :b], :d) == {:select, :a}
      assert Tree.apply_key(key(:end), nodes, [:a, :b], :a) == {:select, :c}
      assert Tree.apply_key(key(:home), nodes, [:a], :a) == :noop
    end

    test "a focused id that is no longer visible re-enters from the near end" do
      # e.g. the app collapsed :a while :d was focused
      nodes = sample()
      assert Tree.apply_key(key(:down), nodes, [], :d) == {:select, :a}
    end
  end

  describe "expand and collapse" do
    test "Right expands a collapsed node, then descends into it" do
      nodes = sample()
      assert Tree.apply_key(key(:right), nodes, [], :a) == {:toggle, :a}
      # already open — the same key now steps in, so repeated presses descend
      assert Tree.apply_key(key(:right), nodes, [:a], :a) == {:select, :b}
    end

    test "Left collapses an expanded node, then steps out" do
      nodes = sample()
      assert Tree.apply_key(key(:left), nodes, [:a], :a) == {:toggle, :a}
      assert Tree.apply_key(key(:left), nodes, [:a], :b) == {:select, :a}
    end

    test "Left at the top level is a noop" do
      assert Tree.apply_key(key(:left), sample(), [], :a) == :noop
    end

    test "Right on a leaf is a noop" do
      assert Tree.apply_key(key(:right), sample(), [:a, :b], :d) == :noop
    end

    test "Enter toggles a branch but submits a leaf" do
      nodes = sample()
      assert Tree.apply_key(key(:enter), nodes, [], :a) == {:toggle, :a}
      assert Tree.apply_key(key(:enter), nodes, [:a, :b], :d) == :submit
    end
  end

  describe "fallthrough" do
    test "unhandled keys reach the app" do
      for k <- [:page_up, :page_down, :tab, :escape, :backspace] do
        assert Tree.apply_key(key(k), sample(), [:a], :a) == :noop
      end
    end

    test "an empty tree is inert" do
      for k <- [:up, :down, :left, :right, :enter, :home, :end] do
        assert Tree.apply_key(key(k), [], [], nil) == :noop
      end
    end
  end
end
