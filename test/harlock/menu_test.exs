defmodule Harlock.MenuTest do
  use ExUnit.Case, async: true

  alias Harlock.Menu

  @items [{:save, "Save"}, {:reload, "Reload"}, {:quit, "Quit"}]

  defp key(k), do: {:key, k, []}

  describe "apply_key/3 movement" do
    test "Down and Up step one item" do
      assert Menu.apply_key(key(:down), :save, @items) == {:select, :reload}
      assert Menu.apply_key(key(:up), :reload, @items) == {:select, :save}
    end

    test "movement wraps at both ends" do
      assert Menu.apply_key(key(:down), :quit, @items) == {:select, :save}
      assert Menu.apply_key(key(:up), :save, @items) == {:select, :quit}
    end

    test "Home and End jump to the ends" do
      assert Menu.apply_key(key(:home), :reload, @items) == {:select, :save}
      assert Menu.apply_key(key(:end), :reload, @items) == {:select, :quit}
    end

    test "Home on the first item is a noop, not a self-select" do
      # a message that selects what is already selected is noise the app would
      # have to filter, so it falls through as a raw key instead
      assert Menu.apply_key(key(:home), :save, @items) == :noop
      assert Menu.apply_key(key(:end), :quit, @items) == :noop
    end

    test "a single-item menu never moves" do
      one = [{:only, "Only"}]
      assert Menu.apply_key(key(:down), :only, one) == :noop
      assert Menu.apply_key(key(:up), :only, one) == :noop
      assert Menu.apply_key(key(:home), :only, one) == :noop
    end

    test "an active id missing from the list enters from the near end" do
      assert Menu.apply_key(key(:down), :gone, @items) == {:select, :save}
      assert Menu.apply_key(key(:up), :gone, @items) == {:select, :quit}
    end
  end

  describe "apply_key/3 commit" do
    test "Enter submits rather than selecting" do
      assert Menu.apply_key(key(:enter), :reload, @items) == :submit
    end

    test "Enter on an empty menu is a noop" do
      assert Menu.apply_key(key(:enter), nil, []) == :noop
    end
  end

  describe "apply_key/3 fallthrough" do
    test "unhandled keys are noop so the app still sees them" do
      for k <- [:left, :right, :page_down, :escape, :tab] do
        assert Menu.apply_key(key(k), :save, @items) == :noop
      end

      assert Menu.apply_key({:key, {:char, ?x}, []}, :save, @items) == :noop
    end

    test "an empty menu is inert" do
      for k <- [:up, :down, :home, :end] do
        assert Menu.apply_key(key(k), nil, []) == :noop
      end
    end
  end
end
