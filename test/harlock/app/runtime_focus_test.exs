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

  # A view that shows the focus, the way a status line or a highlighted border
  # does, reads Harlock.Focus.current/0.
  defmodule FocusLabelApp do
    use Harlock.App

    def init(_), do: %{modal?: false}

    def update({:key, {:char, ?o}, []}, m), do: %{m | modal?: true}
    def update({:key, {:char, ?c}, []}, m), do: %{m | modal?: false}
    def update(_, m), do: m

    def view(m) do
      base =
        vbox(
          children: [
            text("focus: #{inspect(Harlock.Focus.current())}"),
            text("outer1", focusable: :outer1),
            text("outer2", focusable: :outer2)
          ]
        )

      if m.modal?,
        do:
          overlay(
            child: base,
            over: text("inner", focusable: :inner),
            height: 1,
            focus_trap: true
          ),
        else: base
    end
  end

  describe "Focus.current/0 in view/1" do
    defp first_line(h), do: h |> Harlock.Test.render() |> String.split("\n") |> hd()

    test "reports the focus the frame is drawn with on the first frame" do
      h = Harlock.Test.start_app(FocusLabelApp, nil, rows: 5, cols: 30)
      assert first_line(h) =~ "focus: :outer1"
      Harlock.Test.stop(h)
    end

    test "follows focus into a trap as it opens, and back as it closes" do
      h = Harlock.Test.start_app(FocusLabelApp, nil, rows: 5, cols: 30)
      Harlock.Test.send_key(h, :tab)

      Harlock.Test.send_key(h, {:char, ?o})
      assert Harlock.Test.focused(h) == :inner
      assert first_line(h) =~ "focus: :inner"

      Harlock.Test.send_key(h, {:char, ?c})
      assert Harlock.Test.focused(h) == :outer2
      assert first_line(h) =~ "focus: :outer2"
      Harlock.Test.stop(h)
    end
  end

  # Records every {:harlock_focus, from, to} and every routed selection, in the
  # order update/2 receives them.
  defmodule FocusLogApp do
    use Harlock.App

    def init(_), do: %{log: [], modal?: false, show_b?: true}

    def update({:harlock_focus, _, _} = msg, m), do: %{m | log: m.log ++ [msg]}
    def update({:harlock_select, _, _} = msg, m), do: %{m | log: m.log ++ [msg]}
    def update({:key, {:char, ?o}, []}, m), do: %{m | modal?: true}
    def update({:key, {:char, ?c}, []}, m), do: %{m | modal?: false}
    def update({:key, {:char, ?h}, []}, m), do: %{m | show_b?: false}
    def update(_, m), do: m

    def view(m) do
      base =
        vbox(
          constraints: [length: 1, length: 2],
          children: [
            text("a", focusable: :a),
            if(m.show_b?,
              do:
                table(
                  focusable: :b,
                  columns: [column(width: {:fill, 1}, render: &to_string/1)],
                  rows: [:one, :two],
                  row_id: & &1,
                  focused_row: :one,
                  show_header: false
                ),
              else: spacer()
            )
          ]
        )

      if m.modal?,
        do:
          overlay(child: base, over: text("in", focusable: :inner), height: 1, focus_trap: true),
        else: base
    end
  end

  defmodule CurrentApp do
    use Harlock.App

    def init(pid), do: pid

    def update({:harlock_focus, _, to}, pid) do
      send(pid, {:current, to, Harlock.Focus.current()})
      pid
    end

    def update(_, pid), do: pid

    def view(_), do: vbox(children: [text("a", focusable: :a), text("b", focusable: :b)])
  end

  describe "{:harlock_focus, from, to}" do
    defp focus_log(h), do: Harlock.Test.model(h).log

    test "announces the first focus, then each Tab" do
      h = Harlock.Test.start_app(FocusLogApp, nil, rows: 5, cols: 20)
      assert focus_log(h) == [{:harlock_focus, nil, :a}]

      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, :tab)

      assert focus_log(h) == [
               {:harlock_focus, nil, :a},
               {:harlock_focus, :a, :b},
               {:harlock_focus, :b, :a}
             ]

      Harlock.Test.stop(h)
    end

    test "a click announces the focus before the selection it makes" do
      h = Harlock.Test.start_app(FocusLogApp, nil, rows: 5, cols: 20, mouse: true)
      Harlock.Test.send_mouse(h, :press, :left, 1, 3)

      assert focus_log(h) == [
               {:harlock_focus, nil, :a},
               {:harlock_focus, :a, :b},
               {:harlock_select, :b, :two}
             ]

      # A click on what already has focus announces nothing.
      Harlock.Test.send_mouse(h, :press, :left, 1, 2)
      assert List.last(focus_log(h)) == {:harlock_select, :b, :one}
      Harlock.Test.stop(h)
    end

    test "a trap opening and closing announces both moves" do
      h = Harlock.Test.start_app(FocusLogApp, nil, rows: 5, cols: 20)
      Harlock.Test.send_key(h, {:char, ?o})
      Harlock.Test.send_key(h, {:char, ?c})

      assert focus_log(h) == [
               {:harlock_focus, nil, :a},
               {:harlock_focus, :a, :inner},
               {:harlock_focus, :inner, :a}
             ]

      Harlock.Test.stop(h)
    end

    test "the focused element going away announces where focus went" do
      h = Harlock.Test.start_app(FocusLogApp, nil, rows: 5, cols: 20)
      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, {:char, ?h})

      assert List.last(focus_log(h)) == {:harlock_focus, :b, :a}
      Harlock.Test.stop(h)
    end

    test "Focus.current/0 in the clause is the new focus" do
      h = Harlock.Test.start_app(CurrentApp, self(), rows: 5, cols: 20)
      Harlock.Test.send_key(h, :tab)

      assert_receive {:current, :a, :a}
      assert_receive {:current, :b, :b}
      Harlock.Test.stop(h)
    end
  end
end
