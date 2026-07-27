defmodule Harlock.Element.TextareaTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer

  defp row_text(frame, row, width) do
    for col <- 0..(width - 1), into: "" do
      case Buffer.get(frame.buffer, row, col).char do
        nil -> " "
        # second cell of a wide grapheme — the glyph was emitted by the first
        :continuation -> ""
        ch -> <<ch::utf8>>
      end
    end
  end

  describe "construction" do
    test "requires value, cursor and focusable" do
      assert_raise ArgumentError, ~r/requires :value/, fn ->
        textarea(cursor: 0, focusable: :body)
      end

      assert_raise ArgumentError, ~r/requires :cursor/, fn ->
        textarea(value: "", focusable: :body)
      end

      assert_raise ArgumentError, ~r/requires :focusable/, fn ->
        textarea(value: "", cursor: 0)
      end
    end

    test "builds a :textarea element" do
      el = textarea(value: "a", cursor: 0, focusable: :body)
      assert el.type == :textarea
      assert el.children == []
    end
  end

  describe "rendering" do
    test "draws each line on its own row" do
      el = textarea(value: "ab\ncd", cursor: 0, focusable: :body)
      frame = Renderer.render(el, 3, 4)

      assert row_text(frame, 0, 4) == "ab  "
      assert row_text(frame, 1, 4) == "cd  "
      assert row_text(frame, 2, 4) == "    "
    end

    test "clips long lines rather than wrapping" do
      el = textarea(value: "abcdefgh\nx", cursor: 0, focusable: :body)
      frame = Renderer.render(el, 2, 4)

      assert row_text(frame, 0, 4) == "abcd"
      assert row_text(frame, 1, 4) == "x   "
    end

    test "honours :scroll by dropping leading lines" do
      el = textarea(value: "l0\nl1\nl2\nl3", cursor: 0, scroll: 2, focusable: :body)
      # cursor is on line 0, so scroll_to_reveal pulls the view back to it
      frame = Renderer.render(el, 2, 4)
      assert row_text(frame, 0, 4) == "l0  "

      # with the cursor on line 3, :scroll 2 is honoured as-is
      el = textarea(value: "l0\nl1\nl2\nl3", cursor: 9, scroll: 2, focusable: :body)
      frame = Renderer.render(el, 2, 4)
      assert row_text(frame, 0, 4) == "l2  "
      assert row_text(frame, 1, 4) == "l3  "
    end

    test "scrolls to keep the cursor visible when :scroll is left at 0" do
      value = Enum.map_join(0..9, "\n", &"l#{&1}")
      # cursor on the last line, viewport 3 tall -> lines 7..9 visible
      el = textarea(value: value, cursor: String.length(value), focusable: :body)
      frame = Renderer.render(el, 3, 4)

      assert row_text(frame, 0, 4) == "l7  "
      assert row_text(frame, 2, 4) == "l9  "
    end

    test "places the terminal cursor on the right row and column when focused" do
      # "ab\ncd", cursor 4 -> line 1, column 1
      el = textarea(value: "ab\ncd", cursor: 4, focusable: :body)
      frame = Renderer.render(el, 3, 4, :body)

      assert frame.cursor == {1, 1}
      assert frame.focus_rect != nil
    end

    test "cursor column accounts for wide graphemes" do
      # 日 is two columns wide, so a cursor after it sits at column 2
      el = textarea(value: "日x", cursor: 1, focusable: :body)
      frame = Renderer.render(el, 1, 6, :body)

      assert frame.cursor == {0, 2}
    end

    test "cursor row is relative to the scrolled view" do
      value = Enum.map_join(0..9, "\n", &"l#{&1}")
      el = textarea(value: value, cursor: String.length(value), focusable: :body)
      frame = Renderer.render(el, 3, 4, :body)

      # last line is drawn on the last visible row
      assert {2, _col} = frame.cursor
    end

    test "sets no cursor when unfocused" do
      el = textarea(value: "ab", cursor: 1, focusable: :body)
      frame = Renderer.render(el, 1, 4, :other)

      assert frame.cursor == nil
    end

    test "wrap: true breaks long lines across rows" do
      el = textarea(value: "aaa bbb ccc", cursor: 0, wrap: true, focusable: :body)
      frame = Renderer.render(el, 3, 8)

      # "aaa bbb " fills the width exactly; the trailing space is clipped
      assert row_text(frame, 0, 8) == "aaa bbb "
      assert row_text(frame, 1, 8) == "ccc     "
    end

    test "wrap: false (the default) clips instead" do
      el = textarea(value: "aaa bbb ccc", cursor: 0, focusable: :body)
      frame = Renderer.render(el, 3, 8)

      assert row_text(frame, 0, 8) == "aaa bbb "
      assert row_text(frame, 1, 8) == "        "
    end

    test "wrapped rows carry the cursor onto the right row and column" do
      # cursor 8 is the start of the second wrapped row
      el = textarea(value: "aaa bbb ccc", cursor: 8, wrap: true, focusable: :body)
      frame = Renderer.render(el, 3, 8, :body)

      assert frame.cursor == {1, 0}
    end

    test "scrolling counts display rows when wrapping" do
      # wraps at 8 into ["aaa bbb ", "ccc ddd ", "eee"]; a 2-row region with the
      # cursor at the end shows the last two rows
      value = "aaa bbb ccc ddd eee"
      el = textarea(value: value, cursor: String.length(value), wrap: true, focusable: :body)
      frame = Renderer.render(el, 2, 8, :body)

      assert row_text(frame, 0, 8) == "ccc ddd "
      assert row_text(frame, 1, 8) == "eee     "
      assert frame.cursor == {1, 3}
    end

    test "wrapping respects display width for wide graphemes" do
      el = textarea(value: "日本語", cursor: 0, wrap: true, focusable: :body)
      frame = Renderer.render(el, 2, 5)

      # two 2-column graphemes fit in 5; the third wraps
      assert row_text(frame, 0, 5) == "日本 "
      assert row_text(frame, 1, 5) == "語   "
    end

    test "shows the placeholder only when empty and unfocused" do
      el = textarea(value: "", cursor: 0, placeholder: "note", focusable: :body)

      assert row_text(Renderer.render(el, 1, 6, :other), 0, 6) == "note  "
      assert row_text(Renderer.render(el, 1, 6, :body), 0, 6) == "      "
    end
  end
end
