defmodule Harlock.SelectTest do
  use ExUnit.Case, async: true

  alias Harlock.Select

  @items [{:it, "Italy"}, {:fr, "France"}, {:de, "Germany"}]

  defp key(k), do: {:key, k, []}

  describe "closed" do
    test "the action keys open the list" do
      assert Select.apply_key(key(:enter), :it, @items, false) == :submit
      assert Select.apply_key({:key, {:char, ?\s}, []}, :it, @items, false) == :submit
    end

    test "Down opens rather than moving an invisible highlight" do
      assert Select.apply_key(key(:down), :it, @items, false) == :submit
    end

    test "Up does not open" do
      # opening upward from a closed control has no obvious meaning, and it
      # would fight the flip logic that may put the list above anyway
      assert Select.apply_key(key(:up), :it, @items, false) == :noop
    end

    test "no key moves the value while closed" do
      # a closed dropdown that changed value on arrow keys would edit the model
      # without ever showing the user the options. Down opens, Up does nothing,
      # and neither reports a selection.
      assert Select.apply_key(key(:down), :it, @items, false) == :submit
      assert Select.apply_key(key(:up), :it, @items, false) == :noop
      assert Select.apply_key(key(:home), :it, @items, false) == :noop
      assert Select.apply_key(key(:end), :it, @items, false) == :noop
    end

    test "an empty select is inert" do
      assert Select.apply_key(key(:enter), nil, [], false) == :noop
      assert Select.apply_key(key(:down), nil, [], false) == :noop
    end
  end

  describe "open" do
    test "arrows move the highlight and wrap" do
      assert Select.apply_key(key(:down), :it, @items, true) == {:select, :fr}
      assert Select.apply_key(key(:up), :it, @items, true) == {:select, :de}
      assert Select.apply_key(key(:down), :de, @items, true) == {:select, :it}
    end

    test "Home and End jump" do
      assert Select.apply_key(key(:home), :fr, @items, true) == {:select, :it}
      assert Select.apply_key(key(:end), :fr, @items, true) == {:select, :de}
    end

    test "the action keys commit" do
      assert Select.apply_key(key(:enter), :fr, @items, true) == :submit
      assert Select.apply_key({:key, {:char, ?\s}, []}, :fr, @items, true) == :submit
    end

    test "movement that changes nothing is a noop" do
      assert Select.apply_key(key(:home), :it, @items, true) == :noop
    end
  end

  describe "escape" do
    test "falls through in both states so the app decides what cancelling means" do
      assert Select.apply_key(key(:escape), :it, @items, true) == :noop
      assert Select.apply_key(key(:escape), :it, @items, false) == :noop
    end
  end

  describe "fallthrough" do
    test "unrelated keys reach the app" do
      for state <- [true, false], k <- [:left, :right, :page_up, :tab, :backspace] do
        assert Select.apply_key(key(k), :it, @items, state) == :noop
      end
    end
  end
end
