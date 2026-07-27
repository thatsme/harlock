defmodule Harlock.TextBufferTest do
  use ExUnit.Case, async: true

  alias Harlock.TextBuffer

  describe "insert/3" do
    test "into empty" do
      assert TextBuffer.insert("", 0, "h") == {"h", 1}
    end

    test "at the start" do
      assert TextBuffer.insert("ello", 0, "h") == {"hello", 1}
    end

    test "in the middle" do
      assert TextBuffer.insert("helo", 3, "l") == {"hello", 4}
    end

    test "at the end" do
      assert TextBuffer.insert("hell", 4, "o") == {"hello", 5}
    end

    test "multiple characters" do
      assert TextBuffer.insert("ho", 1, "ell") == {"hello", 4}
    end

    test "wide grapheme advances cursor by one grapheme (not columns)" do
      assert TextBuffer.insert("", 0, "東") == {"東", 1}
      assert TextBuffer.insert("東", 1, "京") == {"東京", 2}
    end
  end

  describe "delete_backward/2" do
    test "at start is a no-op" do
      assert TextBuffer.delete_backward("hello", 0) == {"hello", 0}
    end

    test "in the middle" do
      assert TextBuffer.delete_backward("hello", 3) == {"helo", 2}
    end

    test "at the end" do
      assert TextBuffer.delete_backward("hello", 5) == {"hell", 4}
    end

    test "removes a wide grapheme as a single unit" do
      assert TextBuffer.delete_backward("東京", 2) == {"東", 1}
    end
  end

  describe "delete_forward/2" do
    test "at end is a no-op" do
      assert TextBuffer.delete_forward("hello", 5) == {"hello", 5}
    end

    test "in the middle" do
      assert TextBuffer.delete_forward("hello", 2) == {"helo", 2}
    end
  end

  describe "cursor movement" do
    test "move_left clamps at 0" do
      assert TextBuffer.move_left(0) == 0
      assert TextBuffer.move_left(3) == 2
    end

    test "move_right clamps at length" do
      assert TextBuffer.move_right("hi", 0) == 1
      assert TextBuffer.move_right("hi", 2) == 2
    end

    test "home returns 0" do
      assert TextBuffer.home() == 0
    end

    test "end_ returns the grapheme count" do
      assert TextBuffer.end_("hello") == 5
      assert TextBuffer.end_("東京") == 2
    end
  end

  describe "cursor_column/2" do
    test "ASCII is grapheme count" do
      assert TextBuffer.cursor_column("hello", 0) == 0
      assert TextBuffer.cursor_column("hello", 3) == 3
      assert TextBuffer.cursor_column("hello", 5) == 5
    end

    test "wide graphemes are 2 columns each" do
      assert TextBuffer.cursor_column("東京", 0) == 0
      assert TextBuffer.cursor_column("東京", 1) == 2
      assert TextBuffer.cursor_column("東京", 2) == 4
    end

    test "combining marks add 0" do
      nfd = :unicode.characters_to_nfd_binary("héllo")
      # graphemes: ["h", "é", "l", "l", "o"] — width: [1, 1, 1, 1, 1]
      assert TextBuffer.cursor_column(nfd, 2) == 2
    end
  end

  describe "apply_key/3" do
    test "printable char produces an insert" do
      assert TextBuffer.apply_key({:key, {:char, ?a}, []}, "", 0) == {:edit, "a", 1}
    end

    test "shift + char inserts" do
      assert TextBuffer.apply_key({:key, {:char, ?A}, [:shift]}, "", 0) == {:edit, "A", 1}
    end

    # Ctrl-a/e/w/k/u/y/d and Alt-b/f/d became editing keys in the emacs
    # binding set; every other ctrl + char stays outside the vocabulary.
    test "ctrl + char outside the editing set is noop" do
      assert TextBuffer.apply_key({:key, {:char, ?g}, [:ctrl]}, "", 0) == :noop
      assert TextBuffer.apply_key({:key, {:char, ?p}, [:ctrl]}, "", 0) == :noop
    end

    test "backspace deletes back" do
      assert TextBuffer.apply_key({:key, :backspace, []}, "hi", 2) == {:edit, "h", 1}
    end

    test "delete deletes forward" do
      assert TextBuffer.apply_key({:key, :delete, []}, "hi", 0) == {:edit, "i", 0}
    end

    test "arrows move cursor" do
      assert TextBuffer.apply_key({:key, :left, []}, "hi", 1) == {:edit, "hi", 0}
      assert TextBuffer.apply_key({:key, :right, []}, "hi", 0) == {:edit, "hi", 1}
    end

    test "home / end jump" do
      assert TextBuffer.apply_key({:key, :home, []}, "hello", 3) == {:edit, "hello", 0}
      assert TextBuffer.apply_key({:key, :end, []}, "hello", 0) == {:edit, "hello", 5}
    end

    test "enter submits" do
      assert TextBuffer.apply_key({:key, :enter, []}, "hi", 2) == :submit
    end

    test "unknown key is noop" do
      assert TextBuffer.apply_key({:key, :f1, []}, "hi", 0) == :noop
    end
  end

  describe "word motions" do
    test "move_word_left skips separators then the word" do
      assert TextBuffer.move_word_left("hello world", 11) == 6
      assert TextBuffer.move_word_left("hello world", 6) == 0
      assert TextBuffer.move_word_left("hello world", 0) == 0
    end

    test "move_word_right skips separators then the word" do
      assert TextBuffer.move_word_right("hello world", 0) == 5
      assert TextBuffer.move_word_right("hello world", 5) == 11
      assert TextBuffer.move_word_right("hello world", 11) == 11
    end

    test "punctuation runs count as separators" do
      assert TextBuffer.move_word_left("foo.bar", 7) == 4
      assert TextBuffer.move_word_right("foo.bar", 0) == 3
      assert TextBuffer.move_word_left("a  --  b", 8) == 7
    end

    test "cursor mid-word moves to that word's edge" do
      assert TextBuffer.move_word_left("hello", 3) == 0
      assert TextBuffer.move_word_right("hello", 3) == 5
    end

    test "operates on graphemes, not bytes" do
      assert TextBuffer.move_word_right("日本語 x", 0) == 3
      assert TextBuffer.move_word_left("日本語 x", 3) == 0
    end
  end

  describe "kills" do
    test "kill_word_backward returns killed text and moves the cursor" do
      assert TextBuffer.kill_word_backward("hello world", 11) == {"hello ", 6, "world"}
    end

    test "kill_word_forward leaves the cursor put" do
      assert TextBuffer.kill_word_forward("hello world", 0) == {" world", 0, "hello"}
    end

    test "kill_to_end / kill_to_bol" do
      assert TextBuffer.kill_to_end("hello world", 5) == {"hello", 5, " world"}
      assert TextBuffer.kill_to_bol("hello world", 6) == {"world", 0, "hello "}
    end

    test "kills at a boundary remove nothing" do
      assert TextBuffer.kill_to_end("abc", 3) == {"abc", 3, ""}
      assert TextBuffer.kill_to_bol("abc", 0) == {"abc", 0, ""}
      assert TextBuffer.kill_word_backward("abc", 0) == {"abc", 0, ""}
    end
  end

  describe "yank" do
    test "empty ring is a no-op" do
      assert TextBuffer.yank("abc", 1, []) == {"abc", 1}
    end

    test "inserts the head of the ring" do
      assert TextBuffer.yank("abc", 1, ["XY", "old"]) == {"aXYbc", 3}
    end
  end

  describe "apply_key/4 kill ring" do
    test "Ctrl-W then Ctrl-Y round-trips the text" do
      {:edit, v, c, ring} =
        TextBuffer.apply_key({:key, {:char, ?w}, [:ctrl]}, "hello world", 11, [])

      assert {v, c, ring} == {"hello ", 6, ["world"]}

      assert TextBuffer.apply_key({:key, {:char, ?y}, [:ctrl]}, v, c, ring) ==
               {:edit, "hello world", 11, ["world"]}
    end

    test "successive kills stack most-recent-first" do
      {:edit, v, c, r1} = TextBuffer.apply_key({:key, {:char, ?k}, [:ctrl]}, "abc def", 4, [])
      assert {v, c, r1} == {"abc ", 4, ["def"]}

      {:edit, _, _, r2} = TextBuffer.apply_key({:key, {:char, ?u}, [:ctrl]}, v, c, r1)
      assert r2 == ["abc ", "def"]
    end

    test "a kill that removes nothing leaves the ring untouched" do
      {:edit, _, _, ring} =
        TextBuffer.apply_key({:key, {:char, ?k}, [:ctrl]}, "abc", 3, ["prev"])

      assert ring == ["prev"]
    end

    test "ring is capped" do
      ring =
        Enum.reduce(1..25, [], fn i, acc ->
          v = "w#{i}"

          {:edit, _, _, r} =
            TextBuffer.apply_key({:key, {:char, ?u}, [:ctrl]}, v, String.length(v), acc)

          r
        end)

      assert length(ring) == 16
      assert hd(ring) == "w25"
    end

    test "Alt-B / Alt-F move by word without touching the ring" do
      assert TextBuffer.apply_key({:key, {:char, ?b}, [:alt]}, "hello world", 11, ["r"]) ==
               {:edit, "hello world", 6, ["r"]}

      assert TextBuffer.apply_key({:key, {:char, ?f}, [:alt]}, "hello world", 0, ["r"]) ==
               {:edit, "hello world", 5, ["r"]}
    end

    test "Ctrl-A / Ctrl-E are line motions" do
      assert TextBuffer.apply_key({:key, {:char, ?a}, [:ctrl]}, "abc", 2, []) ==
               {:edit, "abc", 0, []}

      assert TextBuffer.apply_key({:key, {:char, ?e}, [:ctrl]}, "abc", 0, []) ==
               {:edit, "abc", 3, []}
    end

    test "ctrl-arrows are word motions, bare arrows are not" do
      assert TextBuffer.apply_key({:key, :left, [:ctrl]}, "hello world", 11, []) ==
               {:edit, "hello world", 6, []}

      assert TextBuffer.apply_key({:key, :left, []}, "hello world", 11, []) ==
               {:edit, "hello world", 10, []}

      assert TextBuffer.apply_key({:key, :right, [:ctrl]}, "hello world", 0, []) ==
               {:edit, "hello world", 5, []}
    end
  end

  describe "apply_key/3 back-compatibility" do
    test "kills still delete when no ring is threaded" do
      assert TextBuffer.apply_key({:key, {:char, ?w}, [:ctrl]}, "hello world", 11) ==
               {:edit, "hello ", 6}
    end

    test "yank is a no-op without a ring" do
      assert TextBuffer.apply_key({:key, {:char, ?y}, [:ctrl]}, "abc", 1) == {:edit, "abc", 1}
    end
  end
end
