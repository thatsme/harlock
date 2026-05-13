defmodule Harlock.Element.WidgetsTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer

  defp row_chars(frame, row, cols) do
    for c <- 0..(cols - 1)//1 do
      case Buffer.get(frame.buffer, row, c).char do
        nil -> " "
        :continuation -> ""
        bin when is_binary(bin) -> bin
        cp when is_integer(cp) -> <<cp::utf8>>
      end
    end
    |> IO.iodata_to_binary()
  end

  describe "progress" do
    test "renders half-filled bar" do
      frame = Renderer.render(progress(value: 50, max: 100), 1, 10)
      # 50/100 * 10 = 5 cells filled
      assert row_chars(frame, 0, 10) == "█████     "
    end

    test "empty bar at value=0" do
      frame = Renderer.render(progress(value: 0, max: 100), 1, 10)
      assert row_chars(frame, 0, 10) == "          "
    end

    test "full bar at value=max" do
      frame = Renderer.render(progress(value: 100, max: 100), 1, 10)
      assert row_chars(frame, 0, 10) == "██████████"
    end

    test "value > max clamps to full" do
      frame = Renderer.render(progress(value: 200, max: 100), 1, 10)
      assert row_chars(frame, 0, 10) == "██████████"
    end

    test "negative value clamps to empty" do
      frame = Renderer.render(progress(value: -10, max: 100), 1, 10)
      assert row_chars(frame, 0, 10) == "          "
    end

    test "explicit :width caps the bar" do
      frame = Renderer.render(progress(value: 50, max: 100, width: 4), 1, 10)
      assert String.starts_with?(row_chars(frame, 0, 10), "██")
    end
  end

  describe "spinner" do
    test "renders frame at rem(tick, length)" do
      frame = Renderer.render(spinner(tick: 0), 1, 1)
      assert row_chars(frame, 0, 1) == "⠋"
    end

    test "cycles through frames as tick increases" do
      frame = Renderer.render(spinner(tick: 1), 1, 1)
      assert row_chars(frame, 0, 1) == "⠙"
    end

    test "wraps modulo length(frames)" do
      f1 = Renderer.render(spinner(tick: 0), 1, 1)
      f2 = Renderer.render(spinner(tick: 10), 1, 1)
      assert row_chars(f1, 0, 1) == row_chars(f2, 0, 1)
    end

    test "custom frames" do
      frame = Renderer.render(spinner(tick: 0, frames: ~w(a b c)), 1, 1)
      assert row_chars(frame, 0, 1) == "a"
    end
  end

  describe "statusbar" do
    test "left + right with middle padding" do
      frame = Renderer.render(statusbar(left: "L", right: "R"), 1, 10)
      assert row_chars(frame, 0, 10) == "L        R"
    end

    test "left-only" do
      frame = Renderer.render(statusbar(left: "hello"), 1, 10)
      assert row_chars(frame, 0, 10) == "hello     "
    end

    test "truncates left when both overflow" do
      frame = Renderer.render(statusbar(left: "long left text", right: "RIGHT"), 1, 10)
      # 10 cols, right is 5, left gets 5
      assert row_chars(frame, 0, 10) == "long RIGHT"
    end
  end

  describe "keybar" do
    test "formats bindings as [k] label" do
      frame = Renderer.render(keybar(bindings: [{?q, "quit"}, {?n, "new"}]), 1, 30)
      assert String.starts_with?(row_chars(frame, 0, 30), "[q] quit  [n] new")
    end

    test "atom keys render via to_string" do
      frame = Renderer.render(keybar(bindings: [{:tab, "next"}]), 1, 20)
      assert String.starts_with?(row_chars(frame, 0, 20), "[tab] next")
    end

    test "custom separator" do
      frame = Renderer.render(keybar(bindings: [{?a, "A"}, {?b, "B"}], separator: " | "), 1, 20)
      assert String.starts_with?(row_chars(frame, 0, 20), "[a] A | [b] B")
    end
  end

  describe "tabs" do
    test "renders inactive + active tab labels" do
      frame = Renderer.render(tabs(items: [{:a, "Alpha"}, {:b, "Beta"}], active: :a), 1, 30)
      assert row_chars(frame, 0, 30) =~ "Alpha"
      assert row_chars(frame, 0, 30) =~ "Beta"
    end

    test "separator between tabs" do
      frame =
        Renderer.render(
          tabs(items: [{:a, "A"}, {:b, "B"}], active: :a, separator: " / "),
          1,
          20
        )

      assert row_chars(frame, 0, 20) =~ " / "
    end
  end

  describe "Harlock.Tabs.apply_key/3" do
    alias Harlock.Tabs

    @items [{:a, "A"}, {:b, "B"}, {:c, "C"}]

    test "Right cycles forward" do
      assert Tabs.apply_key({:key, :right, []}, :a, @items) == {:select, :b}
      assert Tabs.apply_key({:key, :right, []}, :b, @items) == {:select, :c}
    end

    test "Right from last wraps to first" do
      assert Tabs.apply_key({:key, :right, []}, :c, @items) == {:select, :a}
    end

    test "Left from first wraps to last" do
      assert Tabs.apply_key({:key, :left, []}, :a, @items) == {:select, :c}
    end

    test "Home jumps to first" do
      assert Tabs.apply_key({:key, :home, []}, :c, @items) == {:select, :a}
    end

    test "End jumps to last" do
      assert Tabs.apply_key({:key, :end, []}, :a, @items) == {:select, :c}
    end

    test "unknown key is :noop" do
      assert Tabs.apply_key({:key, {:char, ?x}, []}, :a, @items) == :noop
    end

    test "single-item list never cycles" do
      assert Tabs.apply_key({:key, :right, []}, :only, [{:only, "Only"}]) == :noop
      assert Tabs.apply_key({:key, :left, []}, :only, [{:only, "Only"}]) == :noop
    end
  end
end
