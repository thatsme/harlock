defmodule Harlock.App.RuntimeMouseTest do
  use ExUnit.Case, async: true

  alias Harlock.Terminal.Ansi

  # Mouse routing under the test backend. Coordinates passed to send_mouse are
  # 1-indexed, as terminals report them; the layouts below put each element on
  # its own row so row N+1 is element N.

  defmodule FormApp do
    use Harlock.App

    def init(_),
      do: %{notify: false, saves: 0, raw: [], log_offset: 0, picked: 0, show_modal: false}

    def update({:harlock_toggle, :notify, checked}, m), do: %{m | notify: checked}
    def update({:harlock_submit, :save}, m), do: %{m | saves: m.saves + 1}
    def update({:harlock_submit, :modal_ok}, m), do: %{m | show_modal: false}
    def update({:harlock_scroll, :log, offset}, m), do: %{m | log_offset: offset}
    def update({:harlock_select, :rows, id}, m), do: %{m | picked: id}
    def update(:open_modal, m), do: %{m | show_modal: true}
    def update({:mouse, _, _, _, _, _} = ev, m), do: %{m | raw: m.raw ++ [ev]}
    def update(_, m), do: m

    def view(m) do
      base =
        vbox(
          constraints: [length: 1, length: 1, length: 1, length: 3, length: 3],
          children: [
            checkbox("Notify", checked: m.notify, focusable: :notify),
            button("Save", focusable: :save),
            text("plain text"),
            viewport(
              focusable: :log,
              offset: m.log_offset,
              content_height: 20,
              child:
                vbox(
                  constraints: List.duplicate({:length, 1}, 20),
                  children: for(i <- 1..20, do: text("line #{i}"))
                )
            ),
            table(
              focusable: :rows,
              columns: [column(title: "n", width: {:fill, 1}, render: &to_string/1)],
              rows: Enum.to_list(0..9),
              row_id: & &1,
              focused_row: m.picked,
              show_header: false
            )
          ]
        )

      if m.show_modal do
        overlay(
          child: base,
          over: button("OK", focusable: :modal_ok),
          anchor: :top_right,
          width: 10,
          height: 1,
          focus_trap: true
        )
      else
        base
      end
    end
  end

  defp start(opts \\ [mouse: true]),
    do: Harlock.Test.start_app(FormApp, nil, [rows: 9, cols: 30] ++ opts)

  defp model(h), do: Harlock.Test.model(h)

  test "a left press focuses the element under the pointer" do
    h = start()
    assert Harlock.Test.focused(h) == :notify

    Harlock.Test.send_mouse(h, :press, :left, 3, 4)

    assert Harlock.Test.focused(h) == :log
    Harlock.Test.stop(h)
  end

  test "a click presses a button and toggles a checkbox, focusing each" do
    h = start()

    Harlock.Test.send_mouse(h, :press, :left, 2, 2)
    assert model(h).saves == 1
    assert Harlock.Test.focused(h) == :save

    Harlock.Test.send_mouse(h, :press, :left, 2, 1)
    assert model(h).notify == true
    assert Harlock.Test.focused(h) == :notify

    assert model(h).raw == []
    Harlock.Test.stop(h)
  end

  test "the wheel scrolls a viewport three lines without focusing it" do
    h = start()

    Harlock.Test.send_mouse(h, :wheel_down, nil, 2, 5)
    assert model(h).log_offset == 3

    Harlock.Test.send_mouse(h, :wheel_up, nil, 2, 5)
    assert model(h).log_offset == 0
    assert Harlock.Test.focused(h) == :notify

    # Already at the top: nothing to scroll, so the raw event goes to the app.
    Harlock.Test.send_mouse(h, :wheel_up, nil, 2, 5)
    assert [{:mouse, :wheel_up, nil, 2, 5, []}] = model(h).raw
    Harlock.Test.stop(h)
  end

  test "the wheel over a table moves one row" do
    h = start()

    Harlock.Test.send_mouse(h, :wheel_down, nil, 2, 8)

    assert model(h).picked == 1
    Harlock.Test.stop(h)
  end

  test "misses, releases and other buttons arrive raw" do
    h = start()

    Harlock.Test.send_mouse(h, :press, :left, 2, 3)
    Harlock.Test.send_mouse(h, :release, :left, 2, 2)
    Harlock.Test.send_mouse(h, :press, :right, 2, 2)

    assert model(h).raw == [
             {:mouse, :press, :left, 2, 3, []},
             {:mouse, :release, :left, 2, 2, []},
             {:mouse, :press, :right, 2, 2, []}
           ]

    assert model(h).saves == 0
    assert Harlock.Test.focused(h) == :notify
    Harlock.Test.stop(h)
  end

  test "behind an open modal nothing is routed; the modal itself is" do
    h = start()
    Harlock.Test.send_event(h, :open_modal)
    assert Harlock.Test.focused(h) == :modal_ok

    # The panel is the top-right 10 columns of row 1. The Save button on row 2
    # is still visible, but outside the trap.
    Harlock.Test.send_mouse(h, :press, :left, 1, 2)
    assert model(h).saves == 0
    assert Harlock.Test.focused(h) == :modal_ok
    assert [{:mouse, :press, :left, 1, 2, []}] = model(h).raw

    Harlock.Test.send_mouse(h, :press, :left, 25, 1)
    assert model(h).show_modal == false
    Harlock.Test.stop(h)
  end

  test "without mouse: true every mouse event arrives raw" do
    h = start([])

    Harlock.Test.send_mouse(h, :press, :left, 2, 2)

    assert model(h).saves == 0
    assert [{:mouse, :press, :left, 2, 2, []}] = model(h).raw
    Harlock.Test.stop(h)
  end

  describe "terminal sequences" do
    test "entering turns mouse reporting on only when asked" do
      on = Ansi.enter(mouse: true) |> IO.iodata_to_binary()
      off = Ansi.enter() |> IO.iodata_to_binary()

      for mode <- ["1000", "1002", "1006"] do
        assert on =~ "\e[?#{mode}h"
        refute off =~ "\e[?#{mode}h"
      end
    end

    test "leaving always turns it off" do
      leave = Ansi.leave() |> IO.iodata_to_binary()
      for mode <- ["1000", "1002", "1006"], do: assert(leave =~ "\e[?#{mode}l")
    end
  end
end
