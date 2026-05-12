defmodule Harlock.Element.BoxTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.Render.{Buffer, Style, StyleTable}

  defp cell_chars(frame, rows, cols) do
    for r <- 0..(rows - 1), c <- 0..(cols - 1) do
      case Buffer.get(frame.buffer, r, c).char do
        nil -> ?\s
        ch -> ch
      end
    end
    |> List.to_string()
    |> String.codepoints()
    |> Enum.chunk_every(cols)
    |> Enum.map(&Enum.join/1)
  end

  describe "single border" do
    test "draws corners, edges, and contains the child" do
      tree = box(child: text("hi"))
      frame = Renderer.render(tree, 3, 4)

      assert cell_chars(frame, 3, 4) == [
               "┌──┐",
               "│hi│",
               "└──┘"
             ]
    end

    test "different border kinds use different glyphs" do
      for {kind, tl} <- [single: ?┌, double: ?╔, rounded: ?╭, thick: ?┏] do
        frame = Renderer.render(box(child: spacer(), border: kind), 2, 2)
        assert Buffer.get(frame.buffer, 0, 0).char == tl
      end
    end

    test ":none border renders no chrome and gives full region to child" do
      tree = box(child: text("hello"), border: :none)
      frame = Renderer.render(tree, 1, 5)

      assert cell_chars(frame, 1, 5) == ["hello"]
    end
  end

  describe "title" do
    test "is overlaid on the top border, left-aligned by default" do
      tree = box(child: spacer(), title: "T")
      frame = Renderer.render(tree, 3, 6)

      assert cell_chars(frame, 3, 6) == [
               "┌ T ─┐",
               "│    │",
               "└────┘"
             ]
    end

    test "centers when :title_align is :center" do
      tree = box(child: spacer(), title: "T", title_align: :center)
      frame = Renderer.render(tree, 3, 7)

      assert cell_chars(frame, 3, 7) == [
               "┌─ T ─┐",
               "│     │",
               "└─────┘"
             ]
    end

    test "right-aligns when :title_align is :right" do
      tree = box(child: spacer(), title: "T", title_align: :right)
      frame = Renderer.render(tree, 3, 6)

      assert cell_chars(frame, 3, 6) == [
               "┌─ T ┐",
               "│    │",
               "└────┘"
             ]
    end

    test "truncates when wider than the inner span" do
      tree = box(child: spacer(), title: "LongTitle")
      frame = Renderer.render(tree, 3, 6)

      # inner_w is 4; " LongTitle " sliced to 4 chars -> " Lon"
      assert cell_chars(frame, 3, 6) == [
               "┌ Lon┐",
               "│    │",
               "└────┘"
             ]
    end
  end

  describe "padding" do
    test "uniform padding insets the child" do
      tree = box(child: text("x"), padding: 1)
      frame = Renderer.render(tree, 5, 5)

      assert Buffer.get(frame.buffer, 2, 2).char == ?x
      # other interior cells are blank
      assert Buffer.get(frame.buffer, 1, 1).char == nil
    end

    test "asymmetric padding {top, right, bottom, left}" do
      tree = box(child: text("x"), padding: {0, 0, 0, 2})
      frame = Renderer.render(tree, 3, 6)

      # child placed at row 1, col 1 + 2 = 3
      assert Buffer.get(frame.buffer, 1, 3).char == ?x
    end
  end

  describe "small regions" do
    test "skips the border when region is smaller than 2x2 and renders child full-bleed" do
      tree = box(child: text("ab"))
      frame = Renderer.render(tree, 1, 2)

      # no border fits; child gets the whole region
      assert Buffer.get(frame.buffer, 0, 0).char == ?a
      assert Buffer.get(frame.buffer, 0, 1).char == ?b
    end
  end

  describe "focus" do
    test "border style flips to reverse when the box is focused" do
      tree = box(child: spacer(), focusable: :outer)

      unfocused = Renderer.render(tree, 3, 3, nil)
      focused = Renderer.render(tree, 3, 3, :outer)

      focused_corner = Buffer.get(focused.buffer, 0, 0)
      unfocused_corner = Buffer.get(unfocused.buffer, 0, 0)

      refute focused_corner.style_id == unfocused_corner.style_id
      assert %Style{reverse: true} = StyleTable.get(focused.styles, focused_corner.style_id)
    end
  end
end
