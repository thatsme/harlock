defmodule Harlock.Element.RendererTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
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
