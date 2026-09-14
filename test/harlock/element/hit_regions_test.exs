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
        %{id: :below, rect: Rect.new(0, 0, 10, 5)},
        %{id: nil, rect: Rect.new(1, 1, 3, 2)},
        %{id: :above, rect: Rect.new(2, 2, 2, 1)}
      ]

      assert HitRegions.at(regions, 0, 0) == {:hit, :below}
      assert HitRegions.at(regions, 1, 1) == {:hit, nil}
      assert HitRegions.at(regions, 2, 2) == {:hit, :above}
      assert HitRegions.at(regions, 9, 9) == :miss
    end
  end

  describe "translate_and_clip/4" do
    test "shifts rects and drops or trims what falls outside the clip" do
      regions = [
        %{id: :a, rect: Rect.new(0, 0, 5, 1)},
        %{id: :b, rect: Rect.new(4, 0, 5, 3)},
        %{id: :c, rect: Rect.new(20, 0, 5, 1)}
      ]

      clipped = HitRegions.translate_and_clip(regions, 10 - 4, 2, Rect.new(10, 2, 5, 2))

      assert clipped == [%{id: :b, rect: Rect.new(10, 2, 5, 2)}]
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
               %{id: :one, rect: Rect.new(0, 0, 20, 1)},
               %{id: :two, rect: Rect.new(2, 0, 20, 1)}
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
      assert HitRegions.at(regions, occluder.rect.row, occluder.rect.col) == {:hit, :front}
      assert HitRegions.at(regions, 0, 0) == {:hit, :behind}
      assert front.rect == occluder.rect
    end

    test "an open select's panel is an occluder above the tree" do
      tree =
        vbox(
          constraints: [length: 1, length: 1, length: 1],
          children: [
            select(focusable: :pick, items: [{:a, "A"}, {:b, "B"}], value: :a, open: true),
            button("under the panel", focusable: :under),
            text("")
          ]
        )

      regions = regions_for(tree, 3, 20, :pick)

      assert List.last(regions).id == nil
      assert HitRegions.at(regions, 1, 0) == {:hit, nil}
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
      assert HitRegions.at(regions, 1, 0) == {:hit, {:row, 4}}
      assert HitRegions.at(regions, 3, 0) == {:hit, {:row, 6}}
      refute Enum.any?(regions, &(&1.id == {:row, 0}))
      refute Enum.any?(regions, &(&1.id == {:row, 7}))
    end
  end
end
