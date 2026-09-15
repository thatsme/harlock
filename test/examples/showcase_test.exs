defmodule Harlock.Examples.ShowcaseTest do
  use ExUnit.Case, async: false

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "showcase.exs"]))

  setup do
    h = Harlock.Test.start_app(ShowcaseApp, nil, [rows: 30, cols: 100] ++ ShowcaseApp.run_opts())
    on_exit(fn -> Harlock.Test.stop(h) end)
    {:ok, h: h}
  end

  # 1-indexed {col, row} of the first occurrence of `needle` on screen, as a
  # terminal would report a click on it.
  defp position_of(h, needle) do
    h
    |> Harlock.Test.render()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, row} ->
      case :binary.match(line, needle) do
        {byte, _} -> {String.length(binary_part(line, 0, byte)) + 1, row}
        :nomatch -> nil
      end
    end) || flunk("#{inspect(needle)} is not on screen:\n#{Harlock.Test.render(h)}")
  end

  defp click(h, needle, offset \\ 0) do
    {col, row} = position_of(h, needle)
    Harlock.Test.send_mouse(h, :press, :left, col + offset, row)
  end

  test "boots and shows the Logs tab", %{h: h} do
    out = Harlock.Test.render(h)
    assert out =~ "Harlock  Showcase"
    assert out =~ "1. Logs"
    assert out =~ "2. Form"
    assert out =~ "3. Widgets"
    assert out =~ "4. Keys"
  end

  test "Shift-Right cycles to the next tab", %{h: h} do
    Harlock.Test.send_key(h, :right, [:shift])
    out = Harlock.Test.render(h)
    assert out =~ "14 fields"
  end

  test "digit keys switch tabs (outside form)", %{h: h} do
    Harlock.Test.send_key(h, {:char, ?3})
    out = Harlock.Test.render(h)
    assert out =~ "Deployment progress"

    Harlock.Test.send_key(h, {:char, ?4})
    out = Harlock.Test.render(h)
    assert out =~ "press anything"
  end

  test "the tab bar starts focused: Right moves to the next tab, a click to any", %{h: h} do
    assert Harlock.Test.focused(h) == :tabs

    Harlock.Test.send_key(h, :right)
    assert Harlock.Test.model(h).tab == :form

    click(h, "3. Widgets", 1)
    assert Harlock.Test.model(h).tab == :widgets
  end

  test "Logs tab scrolls with arrow keys once the log has focus", %{h: h} do
    out_before = Harlock.Test.render(h)
    assert out_before =~ "  2  ERROR"

    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :logs_viewport

    Enum.each(1..40, fn _ -> Harlock.Test.send_key(h, :down) end)
    out_after = Harlock.Test.render(h)

    refute out_after =~ "  2  ERROR"
    assert out_after =~ "offset: 40"
  end

  test "the wheel scrolls the log without focusing it", %{h: h} do
    {col, row} = position_of(h, "ERROR")
    Harlock.Test.send_mouse(h, :wheel_down, nil, col, row)

    assert Harlock.Test.model(h).logs.offset == 3
    assert Harlock.Test.focused(h) == :tabs
  end

  test "the Widgets tab pauses by button and stops looping by checkbox", %{h: h} do
    Harlock.Test.send_key(h, {:char, ?3})

    click(h, "[ Pause ]", 2)
    refute Harlock.Test.model(h).widgets.working?
    assert Harlock.Test.render(h) =~ "[ Resume ]"

    click(h, "[x] Loop when done", 1)
    refute Harlock.Test.model(h).widgets.loop?
  end

  test "Keys tab captures modified arrow events once the event list has focus", %{h: h} do
    Harlock.Test.send_key(h, {:char, ?4})
    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :capture

    Harlock.Test.send_key(h, :up, [:ctrl])
    Harlock.Test.send_key(h, :right, [:shift, :alt])

    out = Harlock.Test.render(h)
    assert out =~ "ctrl + up"
    assert out =~ "shift + alt + right"
  end

  test "Keys tab shows raw mouse events inside the event list", %{h: h} do
    Harlock.Test.send_key(h, {:char, ?4})
    {col, row} = position_of(h, "Click, right-click")

    Harlock.Test.send_mouse(h, :press, :right, col, row)
    Harlock.Test.send_mouse(h, :wheel_up, nil, col, row, [:ctrl])

    out = Harlock.Test.render(h)
    assert out =~ "mouse press right at #{col},#{row}"
    assert out =~ "mouse ctrl + wheel_up at #{col},#{row}"
  end

  describe "Inputs tab" do
    defp inputs(h), do: Harlock.Test.model(h).inputs

    test "clicks choose radio options, tick the check list and pick from the list box", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?5})

      click(h, "( ) Large", 1)
      click(h, "( ) Courier", 1)
      click(h, "[ ] olives", 1)
      click(h, "stuffed")

      assert %{size: :large, delivery: :courier, crust: :stuffed} = inputs(h)
      assert inputs(h).toppings == MapSet.new([:mozzarella, :olives])
      assert Harlock.Test.render(h) =~ "[x] olives"
    end

    test "the keyboard drives every control, and Save and Reset act on the order", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?5})
      # Tab bar → size → delivery → notes → toppings → crust → gift → save.
      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, :right)
      Harlock.Test.send_key(h, :tab)
      for c <- ~c"no onions", do: Harlock.Test.send_key(h, {:char, c})
      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, {:char, ?\s})
      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, {:char, ?\s})
      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :save_order
      Harlock.Test.send_key(h, :enter)

      assert %{size: :large, delivery: :courier, notes: "no onions", gift: true} = inputs(h)
      assert inputs(h).toppings == MapSet.new([:mozzarella, :basil])

      assert inputs(h).saved == "large classic, mozzarella, basil, courier, gift wrapped"
      assert Harlock.Test.render(h) =~ "✓ Saved: large classic"

      click(h, "[ Reset ]", 2)
      assert inputs(h).saved == nil
      assert inputs(h).size == :medium
    end
  end
end
