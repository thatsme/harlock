defmodule Harlock.Element.SparklineTest do
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
  end

  defp render(el, cols) do
    Renderer.render(el, 1, cols) |> row_text(0, cols)
  end

  describe "construction" do
    test "requires :values" do
      assert_raise ArgumentError, ~r/requires :values/, fn -> sparkline(style: []) end
    end
  end

  describe "scaling" do
    test "spans the ramp from lowest to highest value" do
      # 8 glyphs, 8 evenly spaced values -> one of each, in order
      assert render(sparkline(values: [0, 1, 2, 3, 4, 5, 6, 7]), 8) == "▁▂▃▄▅▆▇█"
    end

    test "shape is preserved regardless of magnitude" do
      small = render(sparkline(values: [1, 2, 3]), 3)
      large = render(sparkline(values: [100, 200, 300]), 3)

      # auto-scaling spans the data, so these are deliberately identical — the
      # widget shows shape, not level
      assert small == large
      # midpoint of 1..3 is (2-1)/(3-1)*7 = 3.5, which rounds up to index 4
      assert small == "▁▅█"
    end

    test "a flat series draws through the middle, not the bottom" do
      # a steady value is not the same as a zero one
      assert render(sparkline(values: [5, 5, 5]), 3) == "▅▅▅"
    end

    test "a single value renders one cell" do
      assert render(sparkline(values: [42]), 4) == "   ▅"
    end

    test "an empty series draws nothing" do
      assert render(sparkline(values: []), 4) == "    "
    end
  end

  describe "pinned scale" do
    test ":min and :max override the derived range" do
      # against 0..100, these three sit near the bottom of the ramp rather than
      # spanning it
      assert render(sparkline(values: [1, 2, 3], min: 0, max: 100), 3) == "▁▁▁"
    end

    test "values outside a pinned range clamp instead of overflowing" do
      assert render(sparkline(values: [-50, 500], min: 0, max: 10), 2) == "▁█"
    end

    test "a pinned range makes magnitude visible" do
      low = render(sparkline(values: [1, 2, 3], min: 0, max: 100), 3)
      high = render(sparkline(values: [98, 99, 100], min: 0, max: 100), 3)

      refute low == high
      assert high == "███"
    end
  end

  describe "width" do
    test "keeps the most recent values and right-aligns them" do
      # newest sample stays at the right edge as history scrolls off the left
      assert render(sparkline(values: [0, 1, 2, 3, 4, 5, 6, 7, 100]), 4) == "▁▁▁█"
    end

    test "a shorter series is right-aligned with leading blanks" do
      assert render(sparkline(values: [0, 7]), 5) == "   ▁█"
    end

    test "a zero-width region draws nothing rather than crashing" do
      frame = Renderer.render(sparkline(values: [1, 2, 3]), 1, 0)
      assert frame.buffer.cols == 0
    end
  end

  describe "glyphs" do
    test "an ASCII ramp can be substituted" do
      ascii = ~w(_ . - ~ = + * #)
      assert render(sparkline(values: [0, 1, 2, 3, 4, 5, 6, 7], glyphs: ascii), 8) == "_.-~=+*#"
    end

    test "a ramp of any length works" do
      assert render(sparkline(values: [0, 1, 2], glyphs: ~w(a b c)), 3) == "abc"
      # two glyphs degenerate to a threshold, which is a legitimate use
      assert render(sparkline(values: [0, 1, 0, 1], glyphs: ~w(. #)), 4) == ".#.#"
    end
  end
end
