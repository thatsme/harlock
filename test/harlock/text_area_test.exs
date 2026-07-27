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

    test "the bare motions carry no goal column, so down then up truncates" do
      # move_up/3 and move_down/3 have nowhere to keep a goal, so a short row
      # permanently truncates the column. Goal-column memory lives in
      # apply_key/6 instead — see the "goal column" block below. Pinned so the
      # split between the two paths stays deliberate.
      down = TextArea.move_down(@sample, 5)
      assert TextArea.position(@sample, down) == {2, 1}
      assert TextArea.position(@sample, TextArea.move_up(@sample, down)) == {1, 1}
    end
  end

  describe "goal column" do
    @up {:key, :up, []}
    @down {:key, :down, []}

    test "descending through a short row and back restores the start column" do
      # rows "ab" / "cd" / "e"; start at row 0 column 2, and row 2 is one column
      # wide, so the middle of the run is where a goal-less motion would lose it.
      assert TextArea.position(@sample, 2) == {0, 2}

      {:edit, v, c1, _ring, g1} = TextArea.apply_key(@down, @sample, 2, [], nil, nil)
      {:edit, ^v, c2, _ring, g2} = TextArea.apply_key(@down, v, c1, [], nil, g1)
      assert TextArea.position(v, c2) == {2, 1}

      {:edit, ^v, c3, _ring, g3} = TextArea.apply_key(@up, v, c2, [], nil, g2)
      {:edit, ^v, c4, _ring, _g} = TextArea.apply_key(@up, v, c3, [], nil, g3)

      assert c4 == 2
      assert TextArea.position(v, c4) == {0, 2}
    end

    test "dropping the goal between motions is what produces the drift" do
      # same keys, goal thrown away each time — the failure the run above avoids
      {:edit, v, c1, _ring, _g} = TextArea.apply_key(@down, @sample, 2, [], nil, nil)
      {:edit, ^v, c2, _ring, _g} = TextArea.apply_key(@down, v, c1, [], nil, nil)
      {:edit, ^v, c3, _ring, _g} = TextArea.apply_key(@up, v, c2, [], nil, nil)
      {:edit, ^v, c4, _ring, _g} = TextArea.apply_key(@up, v, c3, [], nil, nil)

      assert TextArea.position(v, c4) == {0, 1}
      refute c4 == 2
    end

    test "the goal survives a motion that cannot move" do
      # ↑ on the first row moves nothing but still owns the column, so the
      # cursor can come back to it
      {:edit, _v, cursor, _ring, goal} = TextArea.apply_key(@up, @sample, 2, [], nil, nil)
      assert cursor == 2
      assert goal == 2
    end

    test "any other key resets the goal to nil" do
      for event <- [{:key, {:char, ?x}, []}, {:key, :left, []}, {:key, :end, []}] do
        assert {:edit, _v, _c, _ring, nil} =
                 TextArea.apply_key(event, @sample, 2, [], nil, 7)
      end
    end

    test "the goal is a display column, so it clears wide graphemes" do
      # row 0 is "日本" (4 columns), row 1 "x", row 2 "abcd". Column 4 on row 0
      # must survive the one-column row in between.
      value = "日本\nx\nabcd"
      # visual_position reports display cells; position/2 reports graphemes, and
      # the goal is a display column — 4 cells here, not 2 graphemes.
      assert TextArea.visual_position(value, 2, nil) == {0, 4}

      {:edit, v, c1, _ring, g1} = TextArea.apply_key(@down, value, 2, [], nil, nil)
      {:edit, ^v, c2, _ring, g2} = TextArea.apply_key(@down, v, c1, [], nil, g1)
      assert TextArea.visual_position(v, c2, nil) == {2, 4}

      {:edit, ^v, c3, _ring, g3} = TextArea.apply_key(@up, v, c2, [], nil, g2)
      {:edit, ^v, c4, _ring, _g} = TextArea.apply_key(@up, v, c3, [], nil, g3)
      assert c4 == 2
    end
  end

  describe "wrap memoisation" do
    @memo_key :harlock_textarea_wrap_memo

    setup do
      Process.delete(@memo_key)
      on_exit(fn -> Process.delete(@memo_key) end)
      :ok
    end

    test "a repeat call returns the same rows" do
      value = "one two three four five\nsix seven eight"

      first = TextArea.visual_rows(value, 10)
      assert TextArea.visual_rows(value, 10) == first
    end

    test "changing the value recomputes rather than returning stale rows" do
      assert TextArea.visual_rows("aaa bbb", 4) == [{0, "aaa "}, {4, "bbb"}]
      # the memo is keyed by the value, so this cannot hit the entry above
      assert TextArea.visual_rows("zzz", 4) == [{0, "zzz"}]
    end

    test "changing only the width recomputes" do
      value = "aaa bbb ccc"

      narrow = TextArea.visual_rows(value, 4)
      wide = TextArea.visual_rows(value, 80)

      refute narrow == wide
      assert length(wide) == 1
    end

    test "an unwrapped call is memoised separately from a wrapped one" do
      value = "aaa bbb ccc"

      unwrapped = TextArea.visual_rows(value, nil)
      wrapped = TextArea.visual_rows(value, 4)

      assert unwrapped == [{0, value}]
      refute wrapped == unwrapped
      # back to nil must not return the wrapped result
      assert TextArea.visual_rows(value, nil) == unwrapped
    end

    test "callers that wrap visual_rows see consistent results across a cycle" do
      # visual_position and scroll_to_reveal both go through visual_rows; the
      # memo must not change what they compute, only how often they compute it.
      value = "alpha beta gamma\ndelta epsilon"

      Process.delete(@memo_key)
      cold = TextArea.visual_position(value, 20, 8)
      warm = TextArea.visual_position(value, 20, 8)

      assert cold == warm
    end
  end

  describe "expand_tabs" do
    test "advances to the next tab stop rather than emitting a fixed run" do
      assert TextArea.expand_tabs("a\tb", 4) == "a   b"
      assert TextArea.expand_tabs("abc\td", 4) == "abc d"
      assert TextArea.expand_tabs("abcd\te", 4) == "abcd    e"
    end

    test "stops are measured in display cells, not graphemes" do
      # 日 is two columns, so the tab after it advances from column 2 to 4
      assert TextArea.expand_tabs("日\tx", 4) == "日  x"
    end

    test "each line gets its own stops" do
      assert TextArea.expand_tabs("a\tb\ncc\td", 4) == "a   b\ncc  d"
    end

    test "a tab landing exactly on a stop advances a full stop" do
      assert TextArea.expand_tabs("\tx", 4) == "    x"
    end

    test "leaves tab-free values untouched" do
      assert TextArea.expand_tabs(@sample, 4) == @sample
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

  describe "wrap_line" do
    test "packs as many whole words as fit" do
      # "aaa bbb" fills the width exactly, so the row keeps both words and
      # takes the separating space rather than breaking at the earlier one
      assert TextArea.wrap_line("aaa bbb ccc", 7) == ["aaa bbb ", "ccc"]
      assert TextArea.wrap_line("the quick brown fox", 9) == ["the quick ", "brown fox"]
    end

    test "breaks at the last space that fits when the boundary falls mid-word" do
      assert TextArea.wrap_line("aaa bbb", 4) == ["aaa ", "bbb"]
    end

    test "keeps the break space on the preceding row so rows rejoin exactly" do
      for {line, width} <- [{"aaa bbb ccc", 7}, {"the quick brown fox", 9}, {"a b c d", 3}] do
        assert TextArea.wrap_line(line, width) |> Enum.join() == line
      end
    end

    test "hard-breaks a word longer than the width" do
      assert TextArea.wrap_line("abcdefgh", 3) == ["abc", "def", "gh"]
    end

    test "a line that fits is one row" do
      assert TextArea.wrap_line("abc", 3) == ["abc"]
      assert TextArea.wrap_line("abc", 99) == ["abc"]
    end

    test "an empty line is one empty row" do
      assert TextArea.wrap_line("", 5) == [""]
    end

    test "measures display width, so CJK costs two columns" do
      # each of 日本語 is 2 columns wide, so only two fit in 5
      assert TextArea.wrap_line("日本語", 5) == ["日本", "語"]
    end

    test "a width too narrow for one grapheme still makes progress" do
      assert TextArea.wrap_line("日本", 1) == ["日", "本"]
    end
  end

  describe "visual_rows" do
    test "with nil width is just the logical lines" do
      assert TextArea.visual_rows(@sample, nil) == [{0, "ab"}, {3, "cd"}, {6, "e"}]
    end

    test "reports the flat cursor each wrapped row starts at" do
      # "aaa bbb" wrapped at 4 -> ["aaa ", "bbb"], then line "z"
      assert TextArea.visual_rows("aaa bbb\nz", 4) == [{0, "aaa "}, {4, "bbb"}, {8, "z"}]
    end
  end

  describe "visual_position / visual_cursor_at" do
    test "maps a cursor onto the wrapped row it sits in" do
      v = "aaa bbb"
      assert TextArea.visual_position(v, 0, 4) == {0, 0}
      assert TextArea.visual_position(v, 3, 4) == {0, 3}
      # cursor 4 is exactly the wrap boundary -> start of the next row
      assert TextArea.visual_position(v, 4, 4) == {1, 0}
      assert TextArea.visual_position(v, 7, 4) == {1, 3}
    end

    test "columns are display cells, not graphemes" do
      assert TextArea.visual_position("日x", 1, nil) == {0, 2}
    end

    test "round-trips through visual_cursor_at" do
      v = "aaa bbb\nz"

      for c <- 0..String.length(v) do
        {row, col} = TextArea.visual_position(v, c, 4)
        assert TextArea.visual_cursor_at(v, row, col, 4) == c
      end
    end

    test "clamps out-of-range rows and columns" do
      v = "aaa bbb"
      assert TextArea.visual_cursor_at(v, 99, 0, 4) == 4
      assert TextArea.visual_cursor_at(v, 0, 99, 4) == 4
      assert TextArea.visual_cursor_at(v, -1, -1, 4) == 0
    end
  end

  describe "motion with wrapping" do
    # "aaa bbb" wraps at 4 into ["aaa ", "bbb"]
    test "down moves to the next visual row, not past the paragraph" do
      assert TextArea.move_down("aaa bbb", 1, 4) == 5
    end

    test "up moves to the previous visual row" do
      assert TextArea.move_up("aaa bbb", 5, 4) == 1
    end

    test "up on the first visual row is a no-op" do
      assert TextArea.move_up("aaa bbb", 1, 4) == 1
    end

    test "down on the last visual row is a no-op" do
      assert TextArea.move_down("aaa bbb", 5, 4) == 5
    end

    test "home / end act on the visual row" do
      assert TextArea.line_home("aaa bbb", 6, 4) == 4
      assert TextArea.line_end("aaa bbb", 5, 4) == 7
      # first row ends after its trailing space
      assert TextArea.line_end("aaa bbb", 1, 4) == 4
    end

    test "without a width the same calls stay logical" do
      assert TextArea.move_down("aaa bbb", 1, nil) == 1
      assert TextArea.line_end("aaa bbb", 1, nil) == 7
    end

    test "vertical motion preserves the display column across wide graphemes" do
      # row 0 is "日本" (4 columns), row 1 is "ab"; column 2 on row 0 is
      # after 日, which maps to column 2 on row 1 -> after "ab"[0..1]
      v = "日本\nab"
      cursor = TextArea.move_down(v, 1, nil)
      assert TextArea.visual_position(v, cursor, nil) == {1, 2}
    end
  end

  describe "scroll_to_reveal with wrapping" do
    test "counts display rows, not logical lines" do
      # "aaa bbb ccc" wraps at 4 into 3 rows; cursor on the last one
      v = "aaa bbb ccc"
      assert TextArea.scroll_to_reveal(0, v, String.length(v), 2, 4) == 1
    end

    test "unwrapped counts logical lines" do
      assert TextArea.scroll_to_reveal(0, "a\nb\nc", 4, 2, nil) == 1
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
