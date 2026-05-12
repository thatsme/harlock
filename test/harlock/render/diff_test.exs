defmodule Harlock.Render.DiffTest do
  use ExUnit.Case, async: true

  alias Harlock.Render.{Diff, Frame, Style}

  defp render(prev, curr), do: prev |> Diff.diff(curr) |> IO.iodata_to_binary()

  test "blank → blank: no output" do
    assert render(nil, Frame.new(2, 5)) == ""
  end

  test "blank → single char: move + char" do
    frame = Frame.new(2, 5) |> Frame.write(0, 2, "x")
    out = render(nil, frame)
    assert out =~ "\e[1;3H"
    assert out =~ "x"
  end

  test "no change → no output" do
    f1 = Frame.new(2, 5) |> Frame.write(0, 0, "hi")
    f2 = Frame.new(2, 5) |> Frame.write(0, 0, "hi")
    assert render(f1, f2) == ""
  end

  test "single cell change emits one move and one char" do
    f1 = Frame.new(2, 5) |> Frame.write(0, 0, "abcde")
    f2 = Frame.new(2, 5) |> Frame.write(0, 0, "abXde")
    out = render(f1, f2)
    assert out =~ "\e[1;3H"
    assert out =~ "X"
    refute out =~ "a"
    refute out =~ "b"
  end

  test "two adjacent changes share style and emit a single move" do
    f1 = Frame.new(1, 5) |> Frame.write(0, 0, "aaaaa")
    f2 = Frame.new(1, 5) |> Frame.write(0, 0, "abbaa")
    out = render(f1, f2)

    # One move (to col 1), then two contiguous 'b's, no intervening move.
    move_count = out |> String.split("\e[") |> Enum.count(&String.contains?(&1, ";"))
    assert move_count == 1
    assert out =~ "bb"
  end

  test "two non-adjacent changes emit two moves" do
    f1 = Frame.new(1, 10) |> Frame.write(0, 0, "aaaaaaaaaa")
    f2 = Frame.new(1, 10) |> Frame.fill(0, 0, 10, 1, ?a) |> Frame.write(0, 0, "X")
    f2 = Frame.write(f2, 0, 5, "Y")
    out = render(f1, f2)
    assert out =~ "\e[1;1H"
    assert out =~ "\e[1;6H"
    assert out =~ "X"
    assert out =~ "Y"
  end

  test "style change emits SGR" do
    f1 = Frame.new(1, 3) |> Frame.write(0, 0, "abc")
    f2 = Frame.new(1, 3) |> Frame.write(0, 0, "abc", %Style{fg: :red})
    out = render(f1, f2)
    assert out =~ "\e[0;31m"
  end

  # NB: we don't try to be clever about "blank cell with different style
  # renders identically" — the impl conservatively emits a diff whenever the
  # style id changes. That's safe (bg color and reverse video are visually
  # observable on blank cells) and costs only a few SGR bytes per frame.

  test "resize triggers full clear + redraw" do
    f1 = Frame.new(2, 5) |> Frame.write(0, 0, "abc")
    f2 = Frame.new(3, 10) |> Frame.write(0, 0, "abc")
    out = render(f1, f2)
    assert out =~ "\e[2J"
    assert out =~ "a"
  end

  test "char from prev frame is overwritten when curr has blank in same cell" do
    f1 = Frame.new(1, 3) |> Frame.write(0, 1, "X")
    f2 = Frame.new(1, 3)
    out = render(f1, f2)
    # We need to emit a space at (0,1) to erase X.
    assert out =~ "\e[1;2H"
    assert out =~ " "
  end
end
