defmodule Harlock.Element.TreeTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer

  defp row_text(frame, row, width) do
    for col <- 0..(width - 1), into: "" do
      case Buffer.get(frame.buffer, row, col).char do
        nil -> " "
        :continuation -> ""
        ch -> <<ch::utf8>>
      end
    end
    |> String.trim_trailing()
  end

  defp lines(frame, rows, width), do: for(r <- 0..(rows - 1), do: row_text(frame, r, width))

  defp render(el, rows \\ 8, cols \\ 30),
    do: Renderer.render(el, rows, cols) |> lines(rows, cols)

  # a
  # ├── b
  # │   ├── d
  # │   └── e
  # └── c
  defp nodes do
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

  defp tree_el(expanded, opts \\ []) do
    tree(Keyword.merge([nodes: nodes(), expanded: expanded, focused: :a], opts))
  end

  describe "construction" do
    test "requires nodes, expanded and focused" do
      assert_raise ArgumentError, ~r/requires :nodes/, fn -> tree(expanded: [], focused: nil) end
      assert_raise ArgumentError, ~r/requires :expanded/, fn -> tree(nodes: [], focused: nil) end
      assert_raise ArgumentError, ~r/requires :focused/, fn -> tree(nodes: [], expanded: []) end
    end
  end

  describe "guides" do
    test "a collapsed root draws no guide and shows a closed marker" do
      assert render(tree_el([])) |> hd() == "▸ a"
    end

    test "children of a root get an elbow with no trunk before it" do
      # depth 1 sits directly under a top-level node, so there is no column to
      # its left to draw a bar in
      assert render(tree_el([:a])) |> Enum.take(3) == ["▾ a", "├── ▸ b", "└──   c"]
    end

    test "a continuation bar is drawn for an ancestor that still has siblings" do
      # :b is not :a's last child, so :d and :e carry a bar in :b's column
      assert render(tree_el([:a, :b])) |> Enum.take(5) == [
               "▾ a",
               "├── ▾ b",
               "│   ├──   d",
               "│   └──   e",
               "└──   c"
             ]
    end

    test "a last-child ancestor contributes blank space, not a bar" do
      deep = [
        %{
          id: :a,
          label: "a",
          children: [
            %{id: :c, label: "c", children: [%{id: :f, label: "f", children: []}]}
          ]
        }
      ]

      # :c is :a's last child, so :f's ancestor column is blank
      assert Renderer.render(tree(nodes: deep, expanded: [:a, :c], focused: :a), 8, 30)
             |> lines(8, 30)
             |> Enum.take(3) == ["▾ a", "└── ▾ c", "    └──   f"]
    end
  end

  describe "markers" do
    test "leaves are blank-padded so labels stay in one column" do
      rendered = render(tree_el([:a]))
      # "▾ a" / "├── ▸ b" / "└──   c" — :c is a leaf, so two spaces stand in
      assert Enum.at(rendered, 2) == "└──   c"
    end

    test "an expanded node flips its marker" do
      assert render(tree_el([])) |> hd() == "▸ a"
      assert render(tree_el([:a])) |> hd() == "▾ a"
    end

    test "a loading node is marked expandable and suffixed" do
      lazy = [%{id: :r, label: "root", children: :loading}]
      el = tree(nodes: lazy, expanded: [:r], focused: :r)

      assert Renderer.render(el, 4, 30) |> lines(4, 30) |> hd() == "▾ root …"
    end

    test "an unloaded node reads as closed until its children arrive" do
      lazy = [%{id: :r, label: "root", children: :unloaded}]
      el = tree(nodes: lazy, expanded: [], focused: :r)

      assert Renderer.render(el, 4, 30) |> lines(4, 30) |> hd() == "▸ root"
    end
  end

  describe "clipping and scroll" do
    test "rows past the region are clipped" do
      rendered = Renderer.render(tree_el([:a, :b]), 3, 30) |> lines(3, 30)
      assert rendered == ["▾ a", "├── ▾ b", "│   ├──   d"]
    end

    test ":scroll drops leading rows" do
      el = tree_el([:a, :b], scroll: 2)
      assert Renderer.render(el, 3, 30) |> lines(3, 30) |> hd() == "│   ├──   d"
    end
  end
end
