defmodule Harlock.LayoutTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Harlock.Layout
  alias Harlock.Layout.Rect

  defp sizes(direction, region, constraints) do
    rects = Layout.split(region, direction, constraints)
    Enum.map(rects, fn r -> if direction == :vertical, do: r.h, else: r.w end)
  end

  describe "vertical split" do
    test "length-only fills exactly" do
      assert sizes(:vertical, Rect.new(0, 0, 80, 10), length: 3, length: 7) == [3, 7]
    end

    test "fill takes remainder" do
      assert sizes(:vertical, Rect.new(0, 0, 80, 20), length: 3, fill: 1, length: 1) ==
               [3, 16, 1]
    end

    test "fill weights split proportionally" do
      assert sizes(:vertical, Rect.new(0, 0, 80, 24), fill: 1, fill: 2, fill: 1) == [6, 12, 6]
    end

    test "percentage rounds down, leftover absorbed by last fill" do
      assert sizes(:vertical, Rect.new(0, 0, 80, 10), percentage: 33, fill: 1) == [3, 7]
    end

    test "no fill: leftover lands on the last constraint" do
      assert sizes(:vertical, Rect.new(0, 0, 80, 10), length: 3, length: 3) == [3, 7]
    end
  end

  describe "horizontal split" do
    test "splits width, not height" do
      [a, b] = Layout.split(Rect.new(2, 5, 30, 10), :horizontal, length: 10, fill: 1)
      assert a.row == 2 and a.col == 5 and a.w == 10 and a.h == 10
      assert b.row == 2 and b.col == 15 and b.w == 20 and b.h == 10
    end
  end

  describe "rect positioning" do
    test "vertical rects are stacked top-to-bottom from region.row" do
      [a, b, c] =
        Layout.split(Rect.new(4, 2, 30, 12), :vertical, length: 3, fill: 1, length: 1)

      assert a.row == 4 and a.h == 3
      assert b.row == 7 and b.h == 8
      assert c.row == 15 and c.h == 1
      # All have the same col + w
      assert a.col == 2 and a.w == 30
      assert b.col == 2 and b.w == 30
      assert c.col == 2 and c.w == 30
    end
  end

  describe "over-constrained" do
    test "truncates from the tail and logs a warning" do
      log =
        capture_log(fn ->
          assert sizes(:vertical, Rect.new(0, 0, 80, 5), length: 3, length: 3, length: 3) ==
                   [3, 2, 0]
        end)

      assert log =~ "truncating"
    end

    test "never returns a negative size" do
      log =
        capture_log(fn ->
          result = sizes(:vertical, Rect.new(0, 0, 80, 2), length: 10, length: 10)
          assert Enum.all?(result, &(&1 >= 0))
          assert Enum.sum(result) == 2
        end)

      assert log =~ "truncating"
    end
  end

  describe "empty" do
    test "empty constraint list returns empty rects list" do
      assert Layout.split(Rect.new(0, 0, 10, 10), :vertical, []) == []
    end

    test "zero-size region" do
      [a, b] = Layout.split(Rect.new(0, 0, 10, 0), :vertical, length: 1, fill: 1)
      assert a.h == 0
      assert b.h == 0
    end
  end

  describe ":min and :max raise — not implemented in v0.2" do
    test ":min raises ArgumentError" do
      assert_raise ArgumentError, ~r/:min is reserved but not implemented/, fn ->
        sizes(:vertical, Rect.new(0, 0, 80, 10), min: 4, fill: 1)
      end
    end

    test ":max raises ArgumentError" do
      assert_raise ArgumentError, ~r/:max is reserved but not implemented/, fn ->
        sizes(:vertical, Rect.new(0, 0, 80, 10), max: 4, fill: 1)
      end
    end
  end
end
