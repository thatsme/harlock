defmodule Harlock.Element.HitRegionsTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.{HitRegions, Renderer}
  alias Harlock.Layout.Rect

  defp regions_for(tree, rows, cols, focused \\ nil) do
    Renderer.render(tree, rows, cols, focused)
    HitRegions.consume()
  end

  defp ids(regions), do: Enum.map(regions, & &1.id)

  describe "at/3" do
    test "the topmost region containing the point wins; nil ids occlude" do
      regions = [
        %{id: :below, rect: Rect.new(0, 0, 10, 5), part: nil},
        %{id: nil, rect: Rect.new(1, 1, 3, 2), part: nil},
        %{id: :above, rect: Rect.new(2, 2, 2, 1), part: nil}
      ]

      assert HitRegions.at(regions, 0, 0) == {:hit, :below, nil}
      assert HitRegions.at(regions, 1, 1) == {:hit, nil, nil}
      assert HitRegions.at(regions, 2, 2) == {:hit, :above, nil}
      assert HitRegions.at(regions, 9, 9) == :miss
    end
  end

  describe "translate_and_clip/4" do
    test "shifts rects and drops or trims what falls outside the clip" do
      regions = [
        %{id: :a, rect: Rect.new(0, 0, 5, 1), part: nil},
        %{id: :b, rect: Rect.new(4, 0, 5, 3), part: nil},
        %{id: :c, rect: Rect.new(20, 0, 5, 1), part: nil}
      ]

      clipped = HitRegions.translate_and_clip(regions, 10 - 4, 2, Rect.new(10, 2, 5, 2))

      assert clipped == [%{id: :b, rect: Rect.new(10, 2, 5, 2), part: nil}]
    end
  end

  describe "what the renderer records" do
    test "each focusable element, where it was laid out" do
      tree =
        vbox(
          constraints: [length: 1, length: 1, length: 1],
          children: [
            button("One", focusable: :one),
            text("not focusable"),
            checkbox("Two", checked: false, focusable: :two)
          ]
        )

      assert regions_for(tree, 3, 20) == [
               %{id: :one, rect: Rect.new(0, 0, 20, 1), part: nil},
               %{id: :two, rect: Rect.new(2, 0, 20, 1), part: nil}
             ]
    end

    test "handle_mouse: false records an occluder rather than the element" do
      assert ids(regions_for(button("x", focusable: :b, handle_mouse: false), 1, 10)) == [nil]
    end

    test "an overlay panel covers the background, and its own contents sit on top" do
      tree =
        overlay(
          child: button("behind", focusable: :behind),
          over: button("front", focusable: :front),
          width: 10,
          height: 1
        )

      regions = regions_for(tree, 5, 20)

      assert ids(regions) == [:behind, nil, :front]
      [_, occluder, front] = regions
      assert HitRegions.at(regions, occluder.rect.row, occluder.rect.col) == {:hit, :front, nil}
      assert HitRegions.at(regions, 0, 0) == {:hit, :behind, nil}
      assert front.rect == occluder.rect
    end

    test "an open select's panel occludes the tree, and its choices are the select's parts" do
      tree =
        vbox(
          constraints: [length: 1, length: 1, fill: 1],
          children: [
            select(focusable: :pick, items: [{:a, "A"}, {:b, "B"}], value: :a, open: true),
            button("under the panel", focusable: :under),
            text("")
          ]
        )

      regions = regions_for(tree, 6, 20, :pick)

      # The panel opens below the control: border on row 1, choices on rows 2
      # and 3. Row 1 is also where the button is, and the border covers it.
      assert HitRegions.at(regions, 1, 0) == {:hit, nil, nil}
      assert HitRegions.at(regions, 2, 1) == {:hit, :pick, {:choice, :a}}
      assert HitRegions.at(regions, 3, 1) == {:hit, :pick, {:choice, :b}}
    end

    test "tables, menus, tabs and trees record their items as parts" do
      tree =
        vbox(
          constraints: [length: 2, length: 2, length: 1, length: 2],
          children: [
            table(
              focusable: :t,
              columns: [column(width: {:fill, 1}, render: &to_string/1)],
              rows: [:r1, :r2],
              row_id: & &1,
              show_header: false
            ),
            menu(focusable: :m, items: [{:open, "Open"}, {:quit, "Quit"}], active: :open),
            tabs(focusable: :tb, items: [{:one, "One"}, {:two, "Two"}], active: :one),
            tree(
              focusable: :tr,
              nodes: [%{id: :dir, label: "dir", children: [%{id: :f, label: "f", children: []}]}],
              expanded: MapSet.new([:dir]),
              focused: :dir
            )
          ]
        )

      regions = regions_for(tree, 7, 30)

      assert HitRegions.at(regions, 1, 5) == {:hit, :t, {:row, :r2}}
      assert HitRegions.at(regions, 3, 0) == {:hit, :m, {:item, :quit}}
      # Tabs draw as " One " │ " Two ": the second label starts at column 8.
      assert HitRegions.at(regions, 4, 1) == {:hit, :tb, {:tab, :one}}
      assert HitRegions.at(regions, 4, 9) == {:hit, :tb, {:tab, :two}}
      # The expand marker is the first two cells of an expandable node's label.
      assert HitRegions.at(regions, 5, 0) == {:hit, :tr, {:marker, :dir}}
      assert HitRegions.at(regions, 5, 3) == {:hit, :tr, {:node, :dir}}
      assert HitRegions.at(regions, 6, 6) == {:hit, :tr, {:node, :f}}
    end

    test "a viewport's contents are recorded where they are displayed, clipped to it" do
      rows = for i <- 0..9, do: button("row #{i}", focusable: {:row, i})

      tree =
        vbox(
          constraints: [length: 1, length: 3],
          children: [
            text("header"),
            viewport(
              focusable: :log,
              offset: 4,
              content_height: 10,
              child: vbox(constraints: List.duplicate({:length, 1}, 10), children: rows)
            )
          ]
        )

      regions = regions_for(tree, 4, 20)

      # Rows 4..6 are scrolled into the three visible lines, below the header.
      assert HitRegions.at(regions, 1, 0) == {:hit, {:row, 4}, nil}
      assert HitRegions.at(regions, 3, 0) == {:hit, {:row, 6}, nil}
      refute Enum.any?(regions, &(&1.id == {:row, 0}))
      refute Enum.any?(regions, &(&1.id == {:row, 7}))
    end
  end
end
