defmodule Harlock.Examples.CounterNotesTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "counter.exs"]))
  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "notes.exs"]))

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

  describe "counter" do
    setup do
      h = Harlock.Test.start_app(Counter, nil, [rows: 10, cols: 50] ++ Counter.run_opts())
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "keys and buttons change the count, and it never goes below zero", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?+})
      Harlock.Test.send_key(h, {:char, ?+})
      assert Harlock.Test.render(h) =~ "count: 2"

      {col, row} = position_of(h, "[ - ]")
      for _ <- 1..3, do: Harlock.Test.send_mouse(h, :press, :left, col + 2, row)
      assert Harlock.Test.model(h).n == 0

      {col, row} = position_of(h, "[ + ]")
      Harlock.Test.send_mouse(h, :press, :left, col + 2, row)
      assert Harlock.Test.render(h) =~ "count: 1"
    end

    test "Enter presses the focused button", %{h: h} do
      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, :enter)
      assert Harlock.Test.model(h).n == 1
    end
  end

  describe "notes" do
    setup do
      h = Harlock.Test.start_app(Notes, nil, [rows: 12, cols: 60] ++ Notes.run_opts())
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "typing edits, and a click moves the cursor, shown in the status line", %{h: h} do
      for c <- ~c"hello\nworld", do: Harlock.Test.send_key(h, key(c))
      assert Harlock.Test.render(h) =~ ~r/line 2, col 6\s+2 lines/

      {col, row} = position_of(h, "hello")
      Harlock.Test.send_mouse(h, :press, :left, col + 2, row)

      assert Harlock.Test.model(h).cursor == 2
      assert Harlock.Test.render(h) =~ "line 1, col 3"
    end

    defp key(?\n), do: :enter
    defp key(c), do: {:char, c}
  end
end
