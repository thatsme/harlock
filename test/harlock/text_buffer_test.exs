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

    test "ctrl + char is noop" do
      assert TextBuffer.apply_key({:key, {:char, ?a}, [:ctrl]}, "", 0) == :noop
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
end
