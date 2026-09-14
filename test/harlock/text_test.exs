defmodule Harlock.TextTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Harlock.Render.Style
  alias Harlock.Text

  defp plain(lines), do: Enum.map(lines, fn line -> Enum.map_join(line, &elem(&1, 0)) end)

  describe "lines/2 without wrapping" do
    test "a binary is one line with the base style" do
      assert Text.lines("hello") == [[{"hello", %Style{}}]]
    end

    test "a run's style merges over the base style" do
      [[{"a", a}, {"b", b}]] = Text.lines(["a", {"b", fg: :red}], style: [bold: true])

      assert a == %Style{bold: true}
      assert b == %Style{bold: true, fg: :red}
    end

    test "\\n splits lines, inside a run too, and keeps each half's style" do
      lines = Text.lines(["one\ntw", {"o\nthree", fg: :red}])

      assert plain(lines) == ["one", "two", "three"]
      assert [[{"tw", %Style{fg: :default}}, {"o", %Style{fg: :red}}] | _] = tl(lines)
    end

    test "consecutive newlines keep the empty line between them" do
      assert plain(Text.lines("a\n\nb")) == ["a", "", "b"]
    end
  end

  describe "lines/2 with :width" do
    test "breaks at the last space that fits and drops the break space" do
      assert plain(Text.lines("the quick brown fox", width: 10)) == ["the quick", "brown fox"]
    end

    test "breaks mid-word only when a word is wider than the line" do
      assert plain(Text.lines("abcdefghij", width: 4)) == ["abcd", "efgh", "ij"]
    end

    test "a run split across a wrap keeps its style on both lines" do
      [first, second] = Text.lines(["see ", {"important words", fg: :red}], width: 14)

      assert plain([first, second]) == ["see important", "words"]
      assert List.last(first) == {"important", %Style{fg: :red}}
      assert second == [{"words", %Style{fg: :red}}]
    end

    test "measures wide graphemes in display columns" do
      assert plain(Text.lines("日本語テキスト", width: 6)) == ["日本語", "テキス", "ト"]
    end
  end

  describe "height/2 and width/1" do
    test "height counts wrapped rows" do
      assert Text.height("the quick brown fox", 10) == 2
      assert Text.height("a\nb", 10) == 2
    end

    test "empty content has no height" do
      assert Text.height("", 10) == 0
      assert Text.height([], 10) == 0
    end

    test "width is the widest unwrapped line" do
      assert Text.width(["ab", {"cd\nx", bold: true}]) == 4
      assert Text.width("日本") == 4
    end
  end

  describe "validate!/1" do
    test "accepts binaries, runs, and both style forms" do
      content = ["a", {"b", fg: :red}, {"c", %Style{bold: true}}]
      assert Text.validate!(content) == content
    end

    test "rejects a malformed run with the offending value in the message" do
      assert_raise ArgumentError, ~r/:not_a_run/, fn -> Text.validate!(["ok", :not_a_run]) end
    end

    test "rejects an unknown style attribute" do
      assert_raise KeyError, fn -> Text.validate!([{"x", colour: :red}]) end
    end
  end

  describe "wrapping properties" do
    # Words of letters only, so the break-space rule is the only thing that
    # removes characters.
    defp words do
      list_of(string(?a..?z, min_length: 1, max_length: 12), min_length: 1, max_length: 20)
    end

    property "every wrapped line fits the width" do
      check all(ws <- words(), width <- integer(1..30)) do
        for line <- Text.lines(Enum.join(ws, " "), width: width) do
          assert Text.line_width(line) <= width
        end
      end
    end

    property "wrapping loses no characters other than break spaces" do
      check all(ws <- words(), width <- integer(1..30)) do
        text = Enum.join(ws, " ")
        wrapped = text |> Text.lines(width: width) |> plain() |> Enum.join()

        assert String.replace(wrapped, " ", "") == String.replace(text, " ", "")
      end
    end

    property "every character keeps the style of the run it came from" do
      check all(
              ws <- words(),
              width <- integer(1..30),
              styled <- list_of(boolean(), length: length(ws))
            ) do
        runs =
          ws
          |> Enum.zip(styled)
          |> Enum.map(fn {w, red?} -> if red?, do: {w <> " ", fg: :red}, else: w <> " " end)

        expected =
          runs
          |> Enum.flat_map(fn
            {w, _} -> w |> String.trim() |> String.graphemes() |> Enum.map(&{&1, :red})
            w -> w |> String.trim() |> String.graphemes() |> Enum.map(&{&1, :default})
          end)

        actual =
          runs
          |> Text.lines(width: width)
          |> Enum.flat_map(fn line ->
            Enum.flat_map(line, fn {t, style} ->
              t |> String.replace(" ", "") |> String.graphemes() |> Enum.map(&{&1, style.fg})
            end)
          end)

        assert actual == expected
      end
    end

    property "height agrees with lines" do
      check all(ws <- words(), width <- integer(1..30)) do
        text = Enum.join(ws, " ")
        assert Text.height(text, width) == length(Text.lines(text, width: width))
      end
    end
  end
end
