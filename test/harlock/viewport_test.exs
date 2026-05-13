defmodule Harlock.ViewportTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer
  alias Harlock.Viewport

  defp row_chars(frame, row, cols) do
    for c <- 0..(cols - 1)//1 do
      case Buffer.get(frame.buffer, row, c).char do
        nil -> " "
        :continuation -> ""
        bin when is_binary(bin) -> bin
        cp when is_integer(cp) -> <<cp::utf8>>
      end
    end
    |> IO.iodata_to_binary()
  end

  defp content_vbox(lines) do
    vbox(children: Enum.map(lines, &text/1))
  end

  describe "viewport rendering" do
    test "offset=0 shows the top of the child" do
      child = content_vbox(["one", "two", "three", "four", "five"])

      frame =
        Renderer.render(
          viewport(child: child, offset: 0, content_height: 5),
          3,
          10
        )

      assert row_chars(frame, 0, 10) == "one       "
      assert row_chars(frame, 1, 10) == "two       "
      assert row_chars(frame, 2, 10) == "three     "
    end

    test "offset>0 scrolls past the top rows" do
      child = content_vbox(["one", "two", "three", "four", "five"])

      frame =
        Renderer.render(
          viewport(child: child, offset: 2, content_height: 5),
          3,
          10
        )

      assert row_chars(frame, 0, 10) == "three     "
      assert row_chars(frame, 1, 10) == "four      "
      assert row_chars(frame, 2, 10) == "five      "
    end

    test "offset past content leaves blank rows" do
      child = content_vbox(["one", "two"])

      frame =
        Renderer.render(
          viewport(child: child, offset: 5, content_height: 2),
          3,
          10
        )

      assert row_chars(frame, 0, 10) == "          "
      assert row_chars(frame, 1, 10) == "          "
    end

    test "scrollbar reserves the rightmost column" do
      child = content_vbox(["aaaaaaaaaa", "bbbbbbbbbb"])

      frame =
        Renderer.render(
          viewport(
            child: child,
            offset: 0,
            content_height: 2,
            scrollbar: true
          ),
          2,
          10
        )

      # Child gets 9 columns; scrollbar in column 9.
      assert row_chars(frame, 0, 9) == "aaaaaaaaa"
      # content_height <= viewport height, so no thumb — just track bar.
      assert Buffer.get(frame.buffer, 0, 9).char == ?│
    end

    test "scrollbar renders a thumb when content overflows" do
      child = content_vbox(Enum.map(1..20, &"row #{&1}"))

      frame =
        Renderer.render(
          viewport(
            child: child,
            offset: 0,
            content_height: 20,
            scrollbar: true
          ),
          5,
          12
        )

      # At offset 0, the thumb sits at the top: column 11, row 0 is the
      # solid block, lower rows are the track.
      assert Buffer.get(frame.buffer, 0, 11).char == ?█
      assert Buffer.get(frame.buffer, 4, 11).char == ?│
    end

    test "scrollbar thumb moves with offset" do
      child = content_vbox(Enum.map(1..20, &"row #{&1}"))

      frame =
        Renderer.render(
          viewport(
            child: child,
            offset: 15,
            content_height: 20,
            scrollbar: true
          ),
          5,
          12
        )

      # At max offset (15 of 20-5=15) the thumb sits at the bottom.
      assert Buffer.get(frame.buffer, 4, 11).char == ?█
      assert Buffer.get(frame.buffer, 0, 11).char == ?│
    end

    test "zero content_height renders nothing" do
      frame =
        Renderer.render(
          viewport(child: text("x"), offset: 0, content_height: 0),
          3,
          10
        )

      assert row_chars(frame, 0, 10) == "          "
    end
  end

  describe "scroll-into-view (focus pushed beyond visible region)" do
    test "focused text_input below visible region snaps to bottom" do
      # Build 20 rows: text_input is row 15. Viewport h=5, model offset=0.
      # Scroll-into-view should snap effective_offset to 15-5+1 = 11.
      child =
        vbox(
          children:
            Enum.map(0..19, fn i ->
              if i == 15 do
                text_input(value: "hi", cursor: 2, focusable: :input)
              else
                text("row #{i}")
              end
            end)
        )

      frame =
        Renderer.render(
          viewport(child: child, offset: 0, content_height: 20),
          5,
          12,
          :input
        )

      # The focused input should appear in the visible window.
      # effective_offset is 11, so rows 11..15 show. Input at content row
      # 15 → display row 4 (last visible row).
      assert row_chars(frame, 4, 12) == "hi          "
      # Cursor remapped to display coords.
      assert frame.cursor == {4, 2}
    end

    test "focused text_input above visible region snaps to top" do
      child =
        vbox(
          children:
            Enum.map(0..19, fn i ->
              if i == 2 do
                text_input(value: "ab", cursor: 1, focusable: :input)
              else
                text("row #{i}")
              end
            end)
        )

      # Model offset says 10 (well past row 2). Scroll-into-view snaps to 2.
      frame =
        Renderer.render(
          viewport(child: child, offset: 10, content_height: 20),
          5,
          12,
          :input
        )

      # Input at content row 2 → snapped to top, display row 0.
      assert row_chars(frame, 0, 12) == "ab          "
      assert frame.cursor == {0, 1}
    end

    test "no scroll-into-view when focused element is already visible" do
      child =
        vbox(
          children:
            Enum.map(0..19, fn i ->
              if i == 3 do
                text_input(value: "x", cursor: 1, focusable: :input)
              else
                text("row #{i}")
              end
            end)
        )

      # Offset 0, visible rows 0..4, input at row 3 — visible. Use offset.
      frame =
        Renderer.render(
          viewport(child: child, offset: 0, content_height: 20),
          5,
          12,
          :input
        )

      assert row_chars(frame, 3, 12) == "x           "
      assert frame.cursor == {3, 1}
    end
  end

  describe "Viewport.apply_key/4" do
    test ":up / :down moves by one row, clamped" do
      assert Viewport.apply_key(5, 20, 5, :up) == 4
      assert Viewport.apply_key(0, 20, 5, :up) == 0
      assert Viewport.apply_key(5, 20, 5, :down) == 6
      assert Viewport.apply_key(15, 20, 5, :down) == 15
    end

    test ":page_up / :page_down moves by viewport-h - 1" do
      assert Viewport.apply_key(10, 20, 5, :page_down) == 14
      assert Viewport.apply_key(10, 20, 5, :page_up) == 6
    end

    test ":home / :end jump to extremes" do
      assert Viewport.apply_key(10, 20, 5, :home) == 0
      assert Viewport.apply_key(0, 20, 5, :end) == 15
    end

    test "no scroll possible when content fits" do
      assert Viewport.apply_key(0, 3, 5, :down) == 0
      assert Viewport.apply_key(0, 3, 5, :end) == 0
    end

    test "unknown key returns offset unchanged" do
      assert Viewport.apply_key(7, 20, 5, :tab) == 7
    end
  end
end
