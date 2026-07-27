defmodule Harlock.TextAreaTest do
  use ExUnit.Case, async: true

  alias Harlock.TextArea

  # "ab\ncd\ne" — flat indices:
  #   0:a 1:b 2:\n 3:c 4:d 5:\n 6:e
  @sample "ab\ncd\ne"

  describe "lines / line_count" do
    test "splits on newline" do
      assert TextArea.lines(@sample) == ["ab", "cd", "e"]
      assert TextArea.line_count(@sample) == 3
    end

    test "an empty value is one empty line" do
      assert TextArea.lines("") == [""]
      assert TextArea.line_count("") == 1
    end

    test "a trailing newline yields a final empty line" do
      assert TextArea.lines("ab\n") == ["ab", ""]
      assert TextArea.line_count("ab\n") == 2
    end
  end

  describe "position" do
    test "maps flat cursors to line and column" do
      assert TextArea.position(@sample, 0) == {0, 0}
      assert TextArea.position(@sample, 2) == {0, 2}
      assert TextArea.position(@sample, 3) == {1, 0}
      assert TextArea.position(@sample, 5) == {1, 2}
      assert TextArea.position(@sample, 6) == {2, 0}
      assert TextArea.position(@sample, 7) == {2, 1}
    end

    test "clamps past the end" do
      assert TextArea.position(@sample, 999) == {2, 1}
    end

    test "empty value" do
      assert TextArea.position("", 0) == {0, 0}
    end
  end

  describe "cursor_at" do
    test "round-trips with position" do
      for c <- 0..7 do
        {line, col} = TextArea.position(@sample, c)
        assert TextArea.cursor_at(@sample, line, col) == c
      end
    end

    test "clamps both coordinates" do
      assert TextArea.cursor_at(@sample, 0, 99) == 2
      assert TextArea.cursor_at(@sample, 99, 0) == 6
      assert TextArea.cursor_at(@sample, -1, -1) == 0
    end
  end

  describe "vertical motion" do
    test "move_up / move_down keep the column" do
      # line 1 col 1 -> line 0 col 1
      assert TextArea.move_up(@sample, 4) == 1
      # line 0 col 1 -> line 1 col 1
      assert TextArea.move_down(@sample, 1) == 4
    end

    test "no-op at the first and last line" do
      assert TextArea.move_up(@sample, 1) == 1
      assert TextArea.move_down(@sample, 7) == 7
    end

    test "column clamps to a shorter target line" do
      # line 1 col 2 -> line 2 has length 1, so col clamps to 1
      assert TextArea.move_down(@sample, 5) == 7
    end

    test "no goal-column memory: down then up does not restore the column" do
      # documented limitation, pinned so a future goal-column change is deliberate
      down = TextArea.move_down(@sample, 5)
      assert TextArea.position(@sample, down) == {2, 1}
      assert TextArea.position(@sample, TextArea.move_up(@sample, down)) == {1, 1}
    end
  end

  describe "line_home / line_end" do
    test "operate on the current line" do
      assert TextArea.line_home(@sample, 4) == 3
      assert TextArea.line_end(@sample, 3) == 5
    end

    test "on the last line" do
      assert TextArea.line_home(@sample, 7) == 6
      assert TextArea.line_end(@sample, 6) == 7
    end
  end

  describe "apply_key" do
    test "enter inserts a newline and never submits" do
      assert TextArea.apply_key({:key, :enter, []}, "ab", 1) == {:edit, "a\nb", 2}
    end

    test "up / down move by line" do
      assert TextArea.apply_key({:key, :up, []}, @sample, 4) == {:edit, @sample, 1}
      assert TextArea.apply_key({:key, :down, []}, @sample, 1) == {:edit, @sample, 4}
    end

    test "home / end are line-relative" do
      assert TextArea.apply_key({:key, :home, []}, @sample, 4) == {:edit, @sample, 3}
      assert TextArea.apply_key({:key, :end, []}, @sample, 3) == {:edit, @sample, 5}
    end

    test "ctrl-home / ctrl-end jump to the ends of the value" do
      assert TextArea.apply_key({:key, :home, [:ctrl]}, @sample, 4) == {:edit, @sample, 0}
      assert TextArea.apply_key({:key, :end, [:ctrl]}, @sample, 1) == {:edit, @sample, 7}
    end

    test "printable input delegates to TextBuffer" do
      assert TextArea.apply_key({:key, {:char, ?x}, []}, "ab", 1) == {:edit, "axb", 2}
    end

    test "unknown keys are noop" do
      assert TextArea.apply_key({:key, :f1, []}, @sample, 0) == :noop
    end
  end

  describe "cross-line editing falls out of the flat cursor" do
    test "left at a line start lands on the previous line's end" do
      # cursor 3 is line 1 col 0; moving left lands on the newline position
      assert {:edit, @sample, 2} = TextArea.apply_key({:key, :left, []}, @sample, 3)
      assert TextArea.position(@sample, 2) == {0, 2}
    end

    test "backspace at a line start joins the lines" do
      assert TextArea.apply_key({:key, :backspace, []}, @sample, 3) == {:edit, "abcd\ne", 2}
    end

    test "delete at a line end joins the lines" do
      assert TextArea.apply_key({:key, :delete, []}, @sample, 2) == {:edit, "abcd\ne", 2}
    end

    test "word motion crosses lines" do
      # from the very end, one word left is the start of "e"
      assert {:edit, @sample, 6} = TextArea.apply_key({:key, {:char, ?b}, [:alt]}, @sample, 7)
    end
  end

  describe "kill ring threading" do
    test "apply_key/4 threads the ring through to TextBuffer" do
      {:edit, v, c, ring} = TextArea.apply_key({:key, {:char, ?k}, [:ctrl]}, @sample, 3, [])
      assert {v, c, ring} == {"ab\n\ne", 3, ["cd"]}

      assert TextArea.apply_key({:key, {:char, ?y}, [:ctrl]}, v, c, ring) ==
               {:edit, @sample, 5, ["cd"]}
    end

    test "vertical motion leaves the ring alone" do
      assert TextArea.apply_key({:key, :up, []}, @sample, 4, ["r"]) == {:edit, @sample, 1, ["r"]}
    end

    test "Ctrl-K kills to end of line, not end of value" do
      # cursor 3 is the start of line 1 ("cd"); only that line dies
      assert TextArea.apply_key({:key, {:char, ?k}, [:ctrl]}, @sample, 3, []) ==
               {:edit, "ab\n\ne", 3, ["cd"]}
    end

    test "Ctrl-K at end of line kills the newline and joins" do
      # cursor 5 is the end of line 1
      assert TextArea.apply_key({:key, {:char, ?k}, [:ctrl]}, @sample, 5, []) ==
               {:edit, "ab\ncde", 5, ["\n"]}
    end

    test "Ctrl-K at the very end is a no-op that leaves the ring alone" do
      assert TextArea.apply_key({:key, {:char, ?k}, [:ctrl]}, @sample, 7, ["prev"]) ==
               {:edit, @sample, 7, ["prev"]}
    end

    test "Ctrl-U kills to start of line, not start of value" do
      # cursor 5 is the end of line 1 ("cd")
      assert TextArea.apply_key({:key, {:char, ?u}, [:ctrl]}, @sample, 5, []) ==
               {:edit, "ab\n\ne", 3, ["cd"]}
    end
  end

  describe "multi-byte graphemes" do
    test "positions are measured in graphemes, not bytes" do
      v = "日本\n語"
      assert TextArea.position(v, 2) == {0, 2}
      assert TextArea.position(v, 3) == {1, 0}
      assert TextArea.move_up(v, 3) == 0
      assert TextArea.line_end(v, 0) == 2
    end
  end
end
