defmodule Harlock.Element.RendererTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.{Focusables, Renderer}
  alias Harlock.Render.Buffer

  describe "text" do
    test "writes content at (0, 0) in a single-cell-height frame" do
      frame = Renderer.render(text("hi"), 1, 5)
      assert Buffer.get(frame.buffer, 0, 0).char == ?h
      assert Buffer.get(frame.buffer, 0, 1).char == ?i
      assert Buffer.get(frame.buffer, 0, 2).char == nil
    end

    test "clips overflow to the region width" do
      frame = Renderer.render(text("abcdefgh"), 1, 4)
      assert Buffer.get(frame.buffer, 0, 0).char == ?a
      assert Buffer.get(frame.buffer, 0, 3).char == ?d
      # No write at col 4 (out of bounds; Buffer.put no-ops it)
    end

    test "applies style" do
      frame = Renderer.render(text("x", style: [fg: :red]), 1, 1)
      cell = Buffer.get(frame.buffer, 0, 0)
      assert cell.char == ?x
      assert cell.style_id != 0
    end
  end

  describe "text with runs, newlines, wrap and align" do
    alias Harlock.Render.{Style, StyleTable}

    defp row(frame, r) do
      for c <- 0..(frame.buffer.cols - 1), into: "" do
        case Buffer.get(frame.buffer, r, c).char do
          nil -> " "
          cp when is_integer(cp) -> <<cp::utf8>>
          g when is_binary(g) -> g
        end
      end
    end

    defp style_at(frame, r, c),
      do: StyleTable.get(frame.styles, Buffer.get(frame.buffer, r, c).style_id)

    test "each run is drawn in its own style, merged over the element's" do
      el = text(["CPU ", {"92%", fg: :red}], style: [bold: true])
      frame = Renderer.render(el, 1, 10)

      assert row(frame, 0) == "CPU 92%   "
      assert style_at(frame, 0, 0) == %Style{bold: true}
      assert style_at(frame, 0, 4) == %Style{bold: true, fg: :red}
    end

    test "a run keeps its colour while the element is focused" do
      el = text(["ok ", {"!", fg: :red}], focusable: :t)
      frame = Renderer.render(el, 1, 5, :t)

      assert style_at(frame, 0, 0).reverse
      assert %Style{fg: :red, reverse: true} = style_at(frame, 0, 3)
    end

    test "\\n in a plain binary starts a new line instead of being dropped" do
      frame = Renderer.render(text("top\nbottom"), 2, 6)

      assert row(frame, 0) == "top   "
      assert row(frame, 1) == "bottom"
    end

    test "wrap: true wraps to the region width and clips rows past its height" do
      frame = Renderer.render(text("one two three four", wrap: true), 2, 8)

      assert row(frame, 0) == "one two "
      assert row(frame, 1) == "three   "
    end

    test "without wrap, runs are clipped at the region's right edge" do
      frame = Renderer.render(text(["abc", {"defgh", fg: :red}]), 1, 5)
      assert row(frame, 0) == "abcde"
    end

    test "align positions each line independently" do
      frame = Renderer.render(text("ab\nabcd", align: :right), 2, 6)
      assert row(frame, 0) == "    ab"
      assert row(frame, 1) == "  abcd"

      frame = Renderer.render(text("ab\nabcd", align: :center), 2, 6)
      assert row(frame, 0) == "  ab  "
      assert row(frame, 1) == " abcd "
    end

    test "a wide grapheme that does not fit ends the line rather than leaving a gap" do
      # "日" needs two columns and only one is left after "ab"; "x" must not be
      # drawn into that column out of order.
      frame = Renderer.render(text(["ab", "日", "x"]), 1, 3)
      assert row(frame, 0) == "ab "
    end

    test "empty content renders nothing" do
      assert row(Renderer.render(text([]), 1, 3), 0) == "   "
    end
  end

  describe "button and checkbox" do
    defp cells(frame), do: row(frame, 0)
    defp style_of(frame, c), do: style_at(frame, 0, c)

    test "a button is drawn as [ label ]" do
      assert cells(Renderer.render(button("Save", focusable: :save), 1, 10)) == "[ Save ]  "
    end

    test "a checkbox shows its state" do
      assert cells(Renderer.render(checkbox("On", checked: true, focusable: :c), 1, 8)) ==
               "[x] On  "

      assert cells(Renderer.render(checkbox("On", checked: false, focusable: :c), 1, 8)) ==
               "[ ] On  "
    end

    test "a label can carry styled runs" do
      frame = Renderer.render(button(["Delete ", {"all", fg: :red}], focusable: :d), 1, 16)

      assert cells(frame) == "[ Delete all ]  "
      assert style_of(frame, 9).fg == :red
      assert style_of(frame, 2).fg == :default
    end

    test "focus styles the whole control" do
      frame = Renderer.render(checkbox("On", checked: false, focusable: :c), 1, 6, :c)

      assert style_of(frame, 0).reverse
      assert style_of(frame, 4).reverse

      refute Renderer.render(checkbox("On", checked: false, focusable: :c), 1, 6, nil)
             |> style_of(0)
             |> Map.fetch!(:reverse)
    end

    test "the constructors reject what cannot work" do
      assert_raise ArgumentError, ~r/requires :focusable/, fn -> button("x", []) end
      assert_raise ArgumentError, ~r/requires :focusable/, fn -> checkbox("x", checked: true) end

      assert_raise ArgumentError, ~r/:checked to be a boolean/, fn ->
        checkbox("x", focusable: :c)
      end

      assert_raise ArgumentError, ~r/:bad/, fn -> button(["x", :bad], focusable: :b) end
    end

    test "both are focusable and auto-routed" do
      tree =
        vbox(children: [button("a", focusable: :a), checkbox("b", checked: false, focusable: :b)])

      {ids, _traps, routed} = Focusables.collect(tree)

      assert ids == [:a, :b]
      assert Map.keys(routed) |> Enum.sort() == [:a, :b]
    end
  end

  describe "vbox" do
    test "stacks children with length constraints" do
      tree =
        vbox(
          constraints: [length: 1, length: 1],
          children: [text("aa"), text("bb")]
        )

      frame = Renderer.render(tree, 3, 5)
      assert Buffer.get(frame.buffer, 0, 0).char == ?a
      assert Buffer.get(frame.buffer, 1, 0).char == ?b
      assert Buffer.get(frame.buffer, 2, 0).char == nil
    end

    test "fill takes remainder" do
      tree =
        vbox(
          constraints: [length: 1, fill: 1, length: 1],
          children: [text("top"), text("mid"), text("bot")]
        )

      frame = Renderer.render(tree, 5, 5)
      assert Buffer.get(frame.buffer, 0, 0).char == ?t
      assert Buffer.get(frame.buffer, 1, 0).char == ?m
      assert Buffer.get(frame.buffer, 4, 0).char == ?b
    end
  end

  describe "hbox" do
    test "lays out children left-to-right" do
      tree =
        hbox(
          constraints: [length: 2, length: 3],
          children: [text("ab"), text("XYZ")]
        )

      frame = Renderer.render(tree, 1, 5)
      assert Buffer.get(frame.buffer, 0, 0).char == ?a
      assert Buffer.get(frame.buffer, 0, 1).char == ?b
      assert Buffer.get(frame.buffer, 0, 2).char == ?X
      assert Buffer.get(frame.buffer, 0, 4).char == ?Z
    end
  end

  describe "nested" do
    test "vbox of hboxes lays out a grid" do
      tree =
        vbox(
          constraints: [length: 1, length: 1],
          children: [
            hbox(constraints: [length: 1, length: 1], children: [text("A"), text("B")]),
            hbox(constraints: [length: 1, length: 1], children: [text("C"), text("D")])
          ]
        )

      frame = Renderer.render(tree, 2, 2)
      assert Buffer.get(frame.buffer, 0, 0).char == ?A
      assert Buffer.get(frame.buffer, 0, 1).char == ?B
      assert Buffer.get(frame.buffer, 1, 0).char == ?C
      assert Buffer.get(frame.buffer, 1, 1).char == ?D
    end
  end

  describe "spacer" do
    test "leaves its slot blank" do
      tree =
        vbox(
          constraints: [length: 1, length: 1, length: 1],
          children: [text("aa"), spacer(), text("bb")]
        )

      frame = Renderer.render(tree, 3, 5)
      assert Buffer.get(frame.buffer, 0, 0).char == ?a
      assert Buffer.get(frame.buffer, 1, 0).char == nil
      assert Buffer.get(frame.buffer, 2, 0).char == ?b
    end
  end
end
