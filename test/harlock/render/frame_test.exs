defmodule Harlock.Render.FrameTest do
  use ExUnit.Case, async: true

  alias Harlock.Render.{Buffer, Cell, Frame, Style}

  test "new frame is blank" do
    frame = Frame.new(5, 10)
    assert frame.buffer.rows == 5
    assert frame.buffer.cols == 10
    assert Buffer.get(frame.buffer, 0, 0) == %Cell{char: nil, style_id: 0}
  end

  test "write places codepoints in cells" do
    frame =
      Frame.new(3, 10)
      |> Frame.write(1, 2, "abc")

    assert Buffer.get(frame.buffer, 1, 2).char == ?a
    assert Buffer.get(frame.buffer, 1, 3).char == ?b
    assert Buffer.get(frame.buffer, 1, 4).char == ?c
    assert Buffer.get(frame.buffer, 1, 5).char == nil
  end

  test "write interns the style and uses its id" do
    frame =
      Frame.new(1, 5)
      |> Frame.write(0, 0, "x", %Style{bold: true})

    cell = Buffer.get(frame.buffer, 0, 0)
    assert cell.style_id != 0
  end

  test "write clips overflow" do
    frame =
      Frame.new(1, 3)
      |> Frame.write(0, 1, "abcd")

    assert Buffer.get(frame.buffer, 0, 1).char == ?a
    assert Buffer.get(frame.buffer, 0, 2).char == ?b
    # cells beyond the buffer are silently dropped
  end

  test "write handles utf-8" do
    frame =
      Frame.new(1, 5)
      |> Frame.write(0, 0, "café")

    assert Buffer.get(frame.buffer, 0, 0).char == ?c
    assert Buffer.get(frame.buffer, 0, 3).char == ?é
  end

  test "fill paints a rectangle" do
    frame = Frame.new(3, 5) |> Frame.fill(0, 0, 5, 3, ?., %Style{fg: :red})

    for row <- 0..2, col <- 0..4 do
      cell = Buffer.get(frame.buffer, row, col)
      assert cell.char == ?., "cell at #{row},#{col}"
    end
  end

  test "write places wide graphemes with a continuation cell" do
    frame =
      Frame.new(1, 10)
      |> Frame.write(0, 0, "東京")

    # 東 at col 0, continuation at col 1; 京 at col 2, continuation at col 3.
    assert Buffer.get(frame.buffer, 0, 0).char == ?東
    assert Buffer.get(frame.buffer, 0, 1).char == :continuation
    assert Buffer.get(frame.buffer, 0, 2).char == ?京
    assert Buffer.get(frame.buffer, 0, 3).char == :continuation
    assert Buffer.get(frame.buffer, 0, 4).char == nil
  end

  test "write keeps a multi-codepoint grapheme as a binary in a single cell" do
    # NFD "é" is U+0065 + U+0301 — a single grapheme cluster.
    nfd = :unicode.characters_to_nfd_binary("é")

    frame =
      Frame.new(1, 5)
      |> Frame.write(0, 0, nfd)

    # Stored as a binary (the grapheme verbatim), occupying a single cell.
    assert Buffer.get(frame.buffer, 0, 0).char == nfd
    assert Buffer.get(frame.buffer, 0, 1).char == nil
  end

  test "write drops a wide grapheme that wouldn't fit in the last column" do
    # Only 1 column of room at col 4 — wide grapheme can't fit, gets dropped.
    frame =
      Frame.new(1, 5)
      |> Frame.write(0, 4, "東")

    assert Buffer.get(frame.buffer, 0, 4).char == nil
  end

  test "write places an emoji flag as a binary grapheme + continuation" do
    frame =
      Frame.new(1, 5)
      |> Frame.write(0, 0, "🇮🇹")

    cell = Buffer.get(frame.buffer, 0, 0)
    assert is_binary(cell.char)
    assert cell.char == "🇮🇹"
    assert Buffer.get(frame.buffer, 0, 1).char == :continuation
  end
end
