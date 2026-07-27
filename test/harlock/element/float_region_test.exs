defmodule Harlock.Element.FloatRegionTest do
  use ExUnit.Case, async: true

  alias Harlock.Element.Renderer
  alias Harlock.Layout.Rect

  # An 80x24 terminal, because that is the size the clipping bug shows up in.
  @rows 24
  @cols 80

  defp place(anchor, w, h, rows \\ @rows, cols \\ @cols),
    do: Renderer.float_region(anchor, w, h, rows, cols)

  describe "vertical placement" do
    test "opens below the control when there is room" do
      anchor = Rect.new(2, 0, 20, 1)
      assert %Rect{row: 3} = place(anchor, 20, 6)
    end

    test "flips above when below would overflow the bottom" do
      # control on the last row of an 80x24 screen
      anchor = Rect.new(23, 0, 20, 1)
      rect = place(anchor, 20, 6)

      assert rect.row == 17
      assert rect.row + rect.h <= @rows
    end

    test "the flipped panel ends exactly where the control begins" do
      anchor = Rect.new(20, 0, 20, 1)
      rect = place(anchor, 20, 6)
      assert rect.row + rect.h == anchor.row
    end

    test "prefers below when both sides fit" do
      anchor = Rect.new(10, 0, 20, 1)
      assert %Rect{row: 11} = place(anchor, 20, 6)
    end

    test "bottom-aligns when the panel fits on neither side" do
      # 20 rows tall, anchored mid-screen: no room below, none above either
      anchor = Rect.new(12, 0, 20, 1)
      rect = place(anchor, 20, 20)

      assert rect.row == 4
      assert rect.row >= 0
      assert rect.row + rect.h <= @rows
    end

    test "a panel taller than the screen is clamped, never negative" do
      anchor = Rect.new(5, 0, 20, 1)
      rect = place(anchor, 20, 100)

      assert rect.h == @rows
      assert rect.row == 0
    end
  end

  describe "horizontal placement" do
    test "left-aligns with the control when it fits" do
      anchor = Rect.new(0, 10, 20, 1)
      assert %Rect{col: 10} = place(anchor, 20, 4)
    end

    test "shifts left to stay on screen near the right margin" do
      # control starting at column 70 with a 20-wide panel would run to 90
      anchor = Rect.new(0, 70, 10, 1)
      rect = place(anchor, 20, 4)

      assert rect.col == 60
      assert rect.col + rect.w <= @cols
    end

    test "a panel wider than the screen is clamped to the left edge" do
      anchor = Rect.new(0, 40, 10, 1)
      rect = place(anchor, 200, 4)

      assert rect.col == 0
      assert rect.w == @cols
    end
  end

  describe "both flips at once" do
    test "a control in the bottom-right corner opens up and to the left" do
      anchor = Rect.new(23, 76, 4, 1)
      rect = place(anchor, 20, 6)

      assert rect.row == 17
      assert rect.col == 60
      assert rect.row + rect.h <= @rows
      assert rect.col + rect.w <= @cols
    end
  end
end
