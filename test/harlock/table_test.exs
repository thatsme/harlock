defmodule Harlock.TableTest do
  use ExUnit.Case, async: true

  alias Harlock.Table

  @ids [:a, :b, :c]

  defp key(k), do: {:key, k, []}

  describe "select_key/3" do
    test "Down and Up step through the ids" do
      assert Table.select_key(key(:down), @ids, :a) == {:select, :b}
      assert Table.select_key(key(:up), @ids, :b) == {:select, :a}
    end

    test "movement clamps rather than wrapping" do
      # a table is read top-down and is often long; jumping from the last row to
      # the first reads as a glitch. menu wraps because its lists are short.
      assert Table.select_key(key(:up), @ids, :a) == :noop
      assert Table.select_key(key(:down), @ids, :c) == :noop
    end

    test "Home and End jump to the ends" do
      assert Table.select_key(key(:home), @ids, :b) == {:select, :a}
      assert Table.select_key(key(:end), @ids, :b) == {:select, :c}
    end

    test "a jump that changes nothing is a noop" do
      assert Table.select_key(key(:home), @ids, :a) == :noop
      assert Table.select_key(key(:end), @ids, :c) == :noop
    end

    test "a focus that is no longer in the list enters from the near end" do
      # happens when a filter drops the focused row
      assert Table.select_key(key(:down), @ids, :gone) == {:select, :a}
      assert Table.select_key(key(:up), @ids, :gone) == {:select, :c}
    end

    test "an empty table is inert" do
      for k <- [:up, :down, :home, :end] do
        assert Table.select_key(key(k), [], nil) == :noop
      end
    end

    test "unrelated keys fall through" do
      for k <- [:left, :right, :enter, :escape, :page_down] do
        assert Table.select_key(key(k), @ids, :a) == :noop
      end
    end
  end

  describe "scroll_key/4" do
    test "Down and Up move by one row" do
      assert Table.scroll_key(key(:down), 5, 10, false) == {:scroll, 6}
      assert Table.scroll_key(key(:up), 5, 10, false) == {:scroll, 4}
    end

    test "paging moves by a body height less one" do
      assert Table.scroll_key(key(:page_down), 0, 10, false) == {:scroll, 9}
      assert Table.scroll_key(key(:page_up), 20, 10, false) == {:scroll, 11}
    end

    test "Home returns to the top" do
      assert Table.scroll_key(key(:home), 40, 10, false) == {:scroll, 0}
      assert Table.scroll_key(key(:home), 0, 10, false) == :noop
    end

    test "offset never goes below zero" do
      assert Table.scroll_key(key(:up), 0, 10, false) == :noop
      assert Table.scroll_key(key(:page_up), 3, 10, false) == {:scroll, 0}
    end

    test "a short last fetch stops forward movement" do
      # the only end-of-data signal a window function gives: nothing ever asks it
      # for a total, so without this :down would scroll into empty space forever
      assert Table.scroll_key(key(:down), 90, 10, true) == :noop
      assert Table.scroll_key(key(:page_down), 90, 10, true) == :noop
    end

    test "backward movement still works at the end" do
      assert Table.scroll_key(key(:up), 90, 10, true) == {:scroll, 89}
      assert Table.scroll_key(key(:home), 90, 10, true) == {:scroll, 0}
    end

    test ":end is a noop because the last row's position is unknowable" do
      assert Table.scroll_key(key(:end), 5, 10, false) == :noop
    end

    test "a one-row body still pages by at least one" do
      assert Table.scroll_key(key(:page_down), 0, 1, false) == {:scroll, 1}
    end

    test "unrelated keys fall through" do
      for k <- [:left, :right, :enter, :escape] do
        assert Table.scroll_key(key(k), 5, 10, false) == :noop
      end
    end
  end
end
