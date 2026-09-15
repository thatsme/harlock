defmodule Harlock.RadioGroupTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.RadioGroup
  alias Harlock.Render.Buffer

  @items [small: "Small", medium: "Medium", large: "Large"]

  defp row_chars(frame, row, cols) do
    for c <- 0..(cols - 1)//1, into: "" do
      case Buffer.get(frame.buffer, row, c).char do
        nil -> " "
        cp when is_integer(cp) -> <<cp::utf8>>
        bin -> bin
      end
    end
  end

  describe "apply_key/3" do
    test "Down and Right choose the next option, wrapping" do
      assert RadioGroup.apply_key({:key, :down, []}, :small, @items) == {:select, :medium}
      assert RadioGroup.apply_key({:key, :right, []}, :medium, @items) == {:select, :large}
      assert RadioGroup.apply_key({:key, :down, []}, :large, @items) == {:select, :small}
    end

    test "Up and Left choose the previous option, wrapping" do
      assert RadioGroup.apply_key({:key, :up, []}, :medium, @items) == {:select, :small}
      assert RadioGroup.apply_key({:key, :left, []}, :small, @items) == {:select, :large}
    end

    test "Home and End choose the ends, and are a noop when already there" do
      assert RadioGroup.apply_key({:key, :end, []}, :small, @items) == {:select, :large}
      assert RadioGroup.apply_key({:key, :home, []}, :large, @items) == {:select, :small}
      assert RadioGroup.apply_key({:key, :home, []}, :small, @items) == :noop
    end

    test "with nothing chosen, forward keys choose the first and backward the last" do
      assert RadioGroup.apply_key({:key, :down, []}, nil, @items) == {:select, :small}
      assert RadioGroup.apply_key({:key, :up, []}, nil, @items) == {:select, :large}
    end

    test "Enter, Space, other keys and an empty group are a noop" do
      assert RadioGroup.apply_key({:key, :enter, []}, :small, @items) == :noop
      assert RadioGroup.apply_key({:key, {:char, ?\s}, []}, :small, @items) == :noop
      assert RadioGroup.apply_key({:key, {:char, ?x}, []}, :small, @items) == :noop
      assert RadioGroup.apply_key({:key, :down, []}, nil, []) == :noop
    end

    test "a group of one never moves" do
      assert RadioGroup.apply_key({:key, :down, []}, :only, only: "Only") == :noop
    end
  end

  describe "radio_group/1" do
    test "requires :items, :value and :focusable" do
      assert_raise ArgumentError, ~r/:items/, fn -> radio_group(value: nil, focusable: :x) end
      assert_raise ArgumentError, ~r/:value/, fn -> radio_group(items: @items, focusable: :x) end
      assert_raise ArgumentError, ~r/:focusable/, fn -> radio_group(items: @items, value: nil) end
    end

    test "rejects an unknown direction" do
      assert_raise ArgumentError, ~r/:direction/, fn ->
        radio_group(items: @items, value: nil, focusable: :x, direction: :diagonal)
      end
    end

    test "draws one option per row, marking the chosen one" do
      frame = Renderer.render(radio_group(items: @items, value: :medium, focusable: :size), 3, 14)

      assert row_chars(frame, 0, 14) == "( ) Small     "
      assert row_chars(frame, 1, 14) == "(•) Medium    "
      assert row_chars(frame, 2, 14) == "( ) Large     "
    end

    test "draws options side by side, with the gap, clipped at the width" do
      el = radio_group(items: @items, value: :small, focusable: :size, direction: :horizontal)

      assert row_chars(Renderer.render(el, 1, 40), 0, 40) ==
               "(•) Small   ( ) Medium   ( ) Large      "

      assert row_chars(Renderer.render(el, 1, 20), 0, 20) == "(•) Small   ( ) Medi"
    end

    test "a vertical group clips options past its height" do
      frame = Renderer.render(radio_group(items: @items, value: nil, focusable: :size), 2, 14)
      assert row_chars(frame, 1, 14) == "( ) Medium    "
    end
  end

  defmodule App do
    use Harlock.App

    def init(_), do: %{size: :small, colour: nil, raw: []}

    def update({:harlock_select, :size, size}, m), do: %{m | size: size}
    def update({:harlock_select, :colour, colour}, m), do: %{m | colour: colour}
    def update({:key, _, _} = ev, m), do: %{m | raw: m.raw ++ [ev]}
    def update(_, m), do: m

    # Rows 1–3: a vertical group. Row 4: a horizontal one.
    def view(m) do
      vbox(
        constraints: [length: 3, length: 1],
        children: [
          radio_group(
            focusable: :size,
            items: [small: "Small", medium: "Medium", large: "Large"],
            value: m.size
          ),
          radio_group(
            focusable: :colour,
            items: [red: "Red", green: "Green"],
            value: m.colour,
            direction: :horizontal
          )
        ]
      )
    end
  end

  describe "routing" do
    setup do
      h = Harlock.Test.start_app(App, nil, rows: 5, cols: 30, mouse: true)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "the arrows move the choice of the focused group", %{h: h} do
      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).size == :large
      assert Harlock.Test.render(h) =~ "(•) Large"

      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, :right)
      assert Harlock.Test.model(h).colour == :red
    end

    test "keys the group does not use reach update/2", %{h: h} do
      Harlock.Test.send_key(h, :enter)
      Harlock.Test.send_key(h, :home)
      assert Harlock.Test.model(h).raw == [{:key, :enter, []}, {:key, :home, []}]
    end

    test "a click chooses an option and focuses its group", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 3, 2)
      assert Harlock.Test.model(h).size == :medium

      # "( ) Red   ( ) Green" — Green starts at column 11.
      Harlock.Test.send_mouse(h, :press, :left, 13, 4)
      assert Harlock.Test.model(h).colour == :green
      assert Harlock.Test.focused(h) == :colour

      # The gap between options chooses nothing.
      Harlock.Test.send_mouse(h, :press, :left, 9, 4)
      assert Harlock.Test.model(h).colour == :green
    end
  end
end
