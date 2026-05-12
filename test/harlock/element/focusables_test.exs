defmodule Harlock.Element.FocusablesTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Focusables

  test "tree with no focusables returns empty" do
    tree = vbox(children: [text("a"), text("b")])
    assert {[], []} == Focusables.collect(tree)
  end

  test "single focusable text element" do
    tree = text("ok", focusable: :ok_btn)
    assert {[:ok_btn], []} == Focusables.collect(tree)
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

    assert {[:a, :b, :c], []} == Focusables.collect(tree)
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

    assert {[:a, :b, :c, :d], []} == Focusables.collect(tree)
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

    {ids, traps} = Focusables.collect(tree)
    assert ids == [:outside, :in1, :in2, :after]
    assert traps == [[:in1, :in2]]
  end
end
