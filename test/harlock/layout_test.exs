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

  describe ":min" do
    test ":min(n) reserves at least n and grows like fill" do
      # 10 cells: min(3) reserves 3; remaining 7 distributes via fill weight 1
      # for min, weight 1 for fill → equal shares → 3 + 3 = 6 and 0 + 4 = 4
      # (4 includes the +1 roundoff to last active fill)
      assert sizes(:vertical, Rect.new(0, 0, 80, 10), min: 3, fill: 1) == [6, 4]
    end

    test ":min alone takes all available space" do
      assert sizes(:vertical, Rect.new(0, 0, 80, 10), min: 3) == [10]
    end

    test ":min(n) when lower bounds exhaust total takes exactly n" do
      assert sizes(:vertical, Rect.new(0, 0, 80, 10), min: 4, length: 6) == [4, 6]
    end

    test ":min over-constrained truncates and warns" do
      log =
        capture_log(fn ->
          assert sizes(:vertical, Rect.new(0, 0, 80, 5), min: 10) == [5]
        end)

      assert log =~ "truncating"
    end
  end

  describe ":max" do
    test ":max(n) caps growth at n" do
      assert sizes(:vertical, Rect.new(0, 0, 80, 30), max: 10, fill: 1) == [10, 20]
    end

    test ":max alone leaves remainder unallocated" do
      # max 10 in a 30-cell region → takes 10, remaining 20 has nowhere to go
      [r] = Layout.split(Rect.new(0, 0, 80, 30), :vertical, max: 10)
      assert r.h == 10
    end

    test "multiple :max sum below total leaves space unallocated" do
      # Total 30, two :max(10) caps. Each gets 10, 10 unallocated.
      [a, b] = Layout.split(Rect.new(0, 0, 80, 30), :vertical, max: 10, max: 10)
      assert a.h == 10
      assert b.h == 10
    end

    test ":max + :fill: cap-clamped excess flows to fill" do
      # 30 cells, max(5) + fill(1). Equal weight initially → 15 each.
      # max(5) clamps to 5, excess 10 redistributes to fill → 25.
      assert sizes(:vertical, Rect.new(0, 0, 80, 30), max: 5, fill: 1) == [5, 25]
    end
  end

  describe ":min + :max + :fill combinations" do
    test "min(5), max(20), fill(1) share remainder equally up to caps" do
      # Total 30. Lower bounds: [5, 0, 0] = 5. Remaining = 25.
      # Fill weights: [1, 1, 1]. Each gets 25/3 = 8 (one gets +1 roundoff).
      # Sizes: [13, 8, 9] (last fill absorbs roundoff). None hit cap.
      assert sizes(:vertical, Rect.new(0, 0, 80, 30), min: 5, max: 20, fill: 1) == [13, 8, 9]
    end

    test "max-driven cap redistribution converges" do
      # Total 100, three :max with different caps + one :fill.
      # All weight 1. Initial share = 25 each.
      # max(10), max(20) get clamped → excess 15+5=20.
      # Remaining 20 distributes over [max(30), fill] both still active.
      # 10 each → max(30) gets 25+10=35 → clamped to 30, excess 5.
      # Remaining 5 → fill absorbs → fill total 25+10+5=40.
      assert sizes(:vertical, Rect.new(0, 0, 80, 100),
               max: 10,
               max: 20,
               max: 30,
               fill: 1
             ) == [10, 20, 30, 40]
    end

    test "length + percentage + min + fill" do
      # Total 100. length(10) + percentage(20) = 10 + 20 = 30 lower bound.
      # min(5) adds 5 → lower_sum = 35. Remaining 65.
      # Fill weights: [0, 0, 1, 1]. Two active. Each gets 65/2 = 32 (and 33).
      # Result: [10, 20, 5+32=37, 33] (last fill takes roundoff).
      assert sizes(:vertical, Rect.new(0, 0, 80, 100),
               length: 10,
               percentage: 20,
               min: 5,
               fill: 1
             ) == [10, 20, 37, 33]
    end

    test "lower bounds (length + min) sum > total truncates" do
      log =
        capture_log(fn ->
          assert sizes(:vertical, Rect.new(0, 0, 80, 10), length: 8, min: 5) == [8, 2]
        end)

      assert log =~ "truncating"
    end
  end
end
