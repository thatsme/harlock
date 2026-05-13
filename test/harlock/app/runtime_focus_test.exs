defmodule Harlock.App.RuntimeFocusTest do
  use ExUnit.Case, async: true

  # End-to-end runtime focus-traversal tests. The Focusables.collect/1 unit
  # test covers tree walking; this covers the actual Tab/Shift-Tab path
  # through the runtime's handle_info → maybe_handle_focus → focus_next.

  defmodule TwoFieldApp do
    use Harlock.App

    def init(_), do: %{}
    def update(_, m), do: m

    def view(_) do
      vbox(
        children: [
          text("first", focusable: :first),
          text("second", focusable: :second)
        ]
      )
    end
  end

  defmodule ThreeFieldApp do
    use Harlock.App

    def init(_), do: %{}
    def update(_, m), do: m

    def view(_) do
      vbox(
        children: [
          text("a", focusable: :a),
          text("b", focusable: :b),
          text("c", focusable: :c)
        ]
      )
    end
  end

  defmodule ModalApp do
    use Harlock.App

    def init(_), do: %{modal?: false}

    def update({:key, {:char, ?o}, []}, m), do: %{m | modal?: true}
    def update({:key, {:char, ?c}, []}, m), do: %{m | modal?: false}
    def update(_, m), do: m

    def view(%{modal?: false}) do
      vbox(
        children: [
          text("outer1", focusable: :outer1),
          text("outer2", focusable: :outer2)
        ]
      )
    end

    def view(%{modal?: true}) do
      overlay(
        focus_trap: true,
        child:
          vbox(
            children: [
              text("outer1", focusable: :outer1),
              text("outer2", focusable: :outer2)
            ]
          ),
        over:
          vbox(
            children: [
              text("inner1", focusable: :inner1),
              text("inner2", focusable: :inner2)
            ]
          )
      )
    end
  end

  describe "Tab in a flat tree" do
    test "starts focused on the first focusable" do
      h = Harlock.Test.start_app(TwoFieldApp)
      assert Harlock.Test.focused(h) == :first
      Harlock.Test.stop(h)
    end

    test "Tab advances to the next focusable" do
      h = Harlock.Test.start_app(TwoFieldApp)
      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :second
      Harlock.Test.stop(h)
    end

    test "Tab wraps from last to first" do
      h = Harlock.Test.start_app(TwoFieldApp)
      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :first
      Harlock.Test.stop(h)
    end

    test "Tab cycles all three in order" do
      h = Harlock.Test.start_app(ThreeFieldApp)
      assert Harlock.Test.focused(h) == :a

      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :b

      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :c

      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :a

      Harlock.Test.stop(h)
    end

    test "Shift-Tab cycles backward" do
      h = Harlock.Test.start_app(ThreeFieldApp)
      Harlock.Test.send_key(h, :tab, [:shift])
      assert Harlock.Test.focused(h) == :c

      Harlock.Test.send_key(h, :tab, [:shift])
      assert Harlock.Test.focused(h) == :b

      Harlock.Test.stop(h)
    end
  end

  describe "Tab inside a focus_trap overlay" do
    test "focus moves into the trap when modal opens" do
      h = Harlock.Test.start_app(ModalApp)
      assert Harlock.Test.focused(h) == :outer1

      Harlock.Test.send_key(h, {:char, ?o})
      assert Harlock.Test.focused(h) == :inner1
      Harlock.Test.stop(h)
    end

    test "Tab cycles within the trap, not into the background" do
      h = Harlock.Test.start_app(ModalApp)
      Harlock.Test.send_key(h, {:char, ?o})
      assert Harlock.Test.focused(h) == :inner1

      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :inner2

      Harlock.Test.send_key(h, :tab)
      # Wraps within the trap, not to :outer1.
      assert Harlock.Test.focused(h) == :inner1

      Harlock.Test.stop(h)
    end

    test "Shift-Tab also stays within the trap" do
      h = Harlock.Test.start_app(ModalApp)
      Harlock.Test.send_key(h, {:char, ?o})

      Harlock.Test.send_key(h, :tab, [:shift])
      assert Harlock.Test.focused(h) == :inner2

      Harlock.Test.send_key(h, :tab, [:shift])
      assert Harlock.Test.focused(h) == :inner1

      Harlock.Test.stop(h)
    end

    test "focus returns to the previous position when the modal closes" do
      h = Harlock.Test.start_app(ModalApp)
      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :outer2

      Harlock.Test.send_key(h, {:char, ?o})
      assert Harlock.Test.focused(h) == :inner1

      Harlock.Test.send_key(h, {:char, ?c})
      assert Harlock.Test.focused(h) == :outer2

      Harlock.Test.stop(h)
    end
  end

  describe "no focusables" do
    defmodule EmptyApp do
      use Harlock.App
      def init(_), do: %{}
      def update(_, m), do: m
      def view(_), do: text("nothing focusable here")
    end

    test "Tab is a no-op when there's nothing to focus" do
      h = Harlock.Test.start_app(EmptyApp)
      assert Harlock.Test.focused(h) == nil

      # Should not crash, should not change anything.
      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == nil

      Harlock.Test.stop(h)
    end
  end
end
