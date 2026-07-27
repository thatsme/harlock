defmodule Harlock.UndoStackTest do
  use ExUnit.Case, async: true

  alias Harlock.UndoStack

  # Type `text` one grapheme at a time, recording after each keystroke the way an
  # app receiving {:harlock_edit, …} would.
  defp type(stack, text, from \\ {"", 0}) do
    {value, cursor} = from

    text
    |> String.graphemes()
    |> Enum.reduce({stack, value, cursor}, fn g, {s, v, c} ->
      {before, rest} = String.split_at(v, c)
      new_value = before <> g <> rest
      new_cursor = c + 1
      {UndoStack.record(s, {new_value, new_cursor}), new_value, new_cursor}
    end)
  end

  defp undo!(stack) do
    {:ok, snapshot, stack} = UndoStack.undo(stack)
    {snapshot, stack}
  end

  describe "empty stack" do
    test "nothing to undo or redo" do
      stack = UndoStack.new()
      assert UndoStack.undo(stack) == :error
      assert UndoStack.redo(stack) == :error
      refute UndoStack.can_undo?(stack)
      refute UndoStack.can_redo?(stack)
    end

    test "the first recorded state becomes the baseline, not a step" do
      stack = UndoStack.record(UndoStack.new(), {"a", 1})
      refute UndoStack.can_undo?(stack)
    end

    test ":from seeds the baseline so the first edit is undoable" do
      stack = UndoStack.new(from: {"", 0}) |> UndoStack.record({"a", 1})
      assert UndoStack.can_undo?(stack)
      assert {{"", 0}, _} = undo!(stack)
    end
  end

  describe "coalescing a run of insertions" do
    test "typing a word is one undo step, not one per letter" do
      {stack, _v, _c} = type(UndoStack.new(from: {"", 0}), "hello")

      assert UndoStack.depth(stack) == 1
      assert {{"", 0}, stack} = undo!(stack)
      assert UndoStack.undo(stack) == :error
    end

    test "recording an unchanged state changes nothing" do
      {stack, v, c} = type(UndoStack.new(from: {"", 0}), "ab")
      same = UndoStack.record(stack, {v, c})

      assert same == stack
    end
  end

  describe "breaking the run" do
    test "a newline ends the run, so one undo does not swallow the paragraph" do
      stack = UndoStack.new(from: {"", 0})
      {stack, v, c} = type(stack, "one")
      {stack, v, c} = type(stack, "\n", {v, c})
      {stack, _v, _c} = type(stack, "two", {v, c})

      # "one" / newline / "two" — three steps
      assert UndoStack.depth(stack) == 3

      {snapshot, stack} = undo!(stack)
      assert snapshot == {"one\n", 4}

      {snapshot, stack} = undo!(stack)
      assert snapshot == {"one", 3}

      {snapshot, _stack} = undo!(stack)
      assert snapshot == {"", 0}
    end

    test "a cursor jump ends the run without becoming a step of its own" do
      stack = UndoStack.new(from: {"", 0})
      {stack, _v, _c} = type(stack, "abcd")
      assert UndoStack.depth(stack) == 1

      # move the cursor: text unchanged, so this is motion
      stack = UndoStack.record(stack, {"abcd", 0})
      # the run closed, but motion itself is not undoable
      assert UndoStack.depth(stack) == 1

      # typing now starts a fresh step rather than extending the old one
      {stack, _v, _c} = type(stack, "X", {"abcd", 0})
      assert UndoStack.depth(stack) == 2

      assert {{"abcd", 0}, stack} = undo!(stack)
      assert {{"", 0}, _} = undo!(stack)
    end

    test "a delete after an insert starts a new step" do
      stack = UndoStack.new(from: {"", 0})
      {stack, _v, _c} = type(stack, "abc")
      assert UndoStack.depth(stack) == 1

      stack = UndoStack.record(stack, {"ab", 2})
      assert UndoStack.depth(stack) == 2

      assert {{"abc", 3}, stack} = undo!(stack)
      assert {{"", 0}, _} = undo!(stack)
    end

    test "consecutive deletes coalesce into one step" do
      stack =
        UndoStack.new(from: {"abcd", 4})
        |> UndoStack.record({"abc", 3})
        |> UndoStack.record({"ab", 2})
        |> UndoStack.record({"a", 1})

      assert UndoStack.depth(stack) == 1
      assert {{"abcd", 4}, _} = undo!(stack)
    end

    test "an insert after a delete starts a new step" do
      stack =
        UndoStack.new(from: {"abc", 3})
        |> UndoStack.record({"ab", 2})

      {stack, _v, _c} = type(stack, "Z", {"ab", 2})

      assert UndoStack.depth(stack) == 2
    end
  end

  describe "undo mid-run" do
    test "an in-progress run can be undone without waiting for it to close" do
      {stack, _v, _c} = type(UndoStack.new(from: {"", 0}), "typing")

      assert UndoStack.can_undo?(stack)
      assert {{"", 0}, _} = undo!(stack)
    end
  end

  describe "redo" do
    test "round-trips an undone step" do
      {stack, value, cursor} = type(UndoStack.new(from: {"", 0}), "hi")

      {_snapshot, stack} = undo!(stack)
      assert UndoStack.can_redo?(stack)

      assert {:ok, restored, stack} = UndoStack.redo(stack)
      assert restored == {value, cursor}
      refute UndoStack.can_redo?(stack)
    end

    test "walks back and forward through several steps" do
      stack = UndoStack.new(from: {"", 0})
      {stack, v, c} = type(stack, "a")
      {stack, v, c} = type(stack, "\n", {v, c})
      {stack, _v, _c} = type(stack, "b", {v, c})

      {_s1, stack} = undo!(stack)
      {_s2, stack} = undo!(stack)

      # two undos left the cursor at {"a", 1}, so redo moves *forward* from there
      assert {:ok, {"a\n", 2}, stack} = UndoStack.redo(stack)
      assert {:ok, {"a\nb", 3}, _stack} = UndoStack.redo(stack)
    end

    test "a fresh edit discards the redo branch" do
      {stack, _v, _c} = type(UndoStack.new(from: {"", 0}), "abc")
      {_snapshot, stack} = undo!(stack)
      assert UndoStack.can_redo?(stack)

      {stack, _v, _c} = type(stack, "z", {"", 0})
      refute UndoStack.can_redo?(stack)
    end
  end

  describe "bounds" do
    test "the ring drops the oldest entries past the limit" do
      # each newline is its own step, so 10 of them far exceeds a limit of 4
      stack =
        Enum.reduce(1..10, UndoStack.new(limit: 4, from: {"", 0}), fn i, s ->
          UndoStack.record(s, {String.duplicate("\n", i), i})
        end)

      # a motion closes the open run, so what is left is committed history only
      stack = UndoStack.record(stack, {String.duplicate("\n", 10), 0})
      assert UndoStack.depth(stack) == 4
    end

    test "an in-progress run adds at most one step above the limit" do
      stack =
        Enum.reduce(1..10, UndoStack.new(limit: 4, from: {"", 0}), fn i, s ->
          UndoStack.record(s, {String.duplicate("\n", i), i})
        end)

      # the 10th newline's run is still open and is itself undoable
      assert UndoStack.depth(stack) == 5
    end

    test "history stays bounded no matter how much is recorded" do
      stack =
        Enum.reduce(1..500, UndoStack.new(limit: 10, from: {"", 0}), fn i, s ->
          UndoStack.record(s, {String.duplicate("\n", i), i})
        end)

      assert UndoStack.depth(stack) <= 11

      # and it can actually be walked all the way back without error
      drained =
        Stream.repeatedly(fn -> :step end)
        |> Enum.reduce_while(stack, fn _, s ->
          case UndoStack.undo(s) do
            {:ok, _snapshot, next} -> {:cont, next}
            :error -> {:halt, s}
          end
        end)

      assert UndoStack.undo(drained) == :error
    end

    test "undo stops cleanly once history is exhausted" do
      {stack, _v, _c} = type(UndoStack.new(from: {"", 0}), "ab")
      {_snapshot, stack} = undo!(stack)

      assert UndoStack.undo(stack) == :error
      refute UndoStack.can_undo?(stack)
    end
  end

  describe "reset/2" do
    test "discards history so undo cannot cross into the old document" do
      {stack, _v, _c} = type(UndoStack.new(from: {"", 0}), "old text")
      stack = UndoStack.reset(stack, {"brand new", 9})

      refute UndoStack.can_undo?(stack)
      refute UndoStack.can_redo?(stack)

      # edits after the reset undo back to the new baseline, not the old content
      {stack, _v, _c} = type(stack, "!", {"brand new", 9})
      assert {{"brand new", 9}, _} = undo!(stack)
    end
  end
end
