defmodule Harlock.Element.FocusablesTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Focusables

  test "tree with no focusables returns empty" do
    tree = vbox(children: [text("a"), text("b")])
    assert {[], [], %{}} == Focusables.collect(tree)
  end

  test "single focusable text element" do
    tree = text("ok", focusable: :ok_btn)
    assert {[:ok_btn], [], %{}} == Focusables.collect(tree)
  end

  test "siblings in DFS order" do
    tree =
      vbox(
        children: [
          text("a", focusable: :a),
          text("b", focusable: :b),
          text("c", focusable: :c)
        ]
      )

    assert {[:a, :b, :c], [], %{}} == Focusables.collect(tree)
  end

  test "nested DFS order" do
    tree =
      vbox(
        children: [
          text("a", focusable: :a),
          hbox(children: [text("b", focusable: :b), text("c", focusable: :c)]),
          text("d", focusable: :d)
        ]
      )

    assert {[:a, :b, :c, :d], [], %{}} == Focusables.collect(tree)
  end

  test "focus_trap captures its subtree ids as one trap" do
    tree =
      vbox(
        children: [
          text("outside", focusable: :outside),
          vbox(
            focus_trap: true,
            children: [
              text("in1", focusable: :in1),
              text("in2", focusable: :in2)
            ]
          ),
          text("after", focusable: :after)
        ]
      )

    {ids, traps, routed_widgets} = Focusables.collect(tree)
    assert ids == [:outside, :in1, :in2, :after]
    assert traps == [[:in1, :in2]]
    assert routed_widgets == %{}
  end

  describe "routed_widgets (R2)" do
    test "focusable viewport is indexed by its focus id" do
      vp =
        viewport(focusable: :log, offset: 0, content_height: 10, child: text("x"))

      {ids, traps, routed_widgets} = Focusables.collect(vp)
      assert ids == [:log]
      assert traps == []
      assert is_map_key(routed_widgets, :log)
      assert routed_widgets[:log].type == :viewport
    end

    test "viewport without :focusable is not indexed" do
      vp = viewport(offset: 0, content_height: 10, child: text("x"))
      {_, _, routed_widgets} = Focusables.collect(vp)
      assert routed_widgets == %{}
    end

    test "non-viewport focusable elements are not indexed (not auto-routable)" do
      tree = text("btn", focusable: :ok)
      {_, _, routed_widgets} = Focusables.collect(tree)
      assert routed_widgets == %{}
    end

    test "handle_keys: false opts out of indexing" do
      vp =
        viewport(
          focusable: :log,
          handle_keys: false,
          offset: 0,
          content_height: 10,
          child: text("x")
        )

      {ids, _, routed_widgets} = Focusables.collect(vp)
      assert ids == [:log]
      assert routed_widgets == %{}
    end
  end
end
