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

  defmodule PaneApp do
    use Harlock.App

    def init(_), do: %{saves: 0, raw: [], offset: 0}

    def update({:harlock_submit, :save}, m), do: %{m | saves: m.saves + 1}
    def update({:harlock_scroll, :log, offset}, m), do: %{m | offset: offset}
    def update({:mouse, _, _, _, _, _} = ev, m), do: %{m | raw: m.raw ++ [ev]}
    def update(_, m), do: m

    # Rows 1–3: a button in a padded box. Rows 4–8: a viewport in a box.
    # Row 9: a box that opts out of mouse.
    def view(m) do
      vbox(
        constraints: [length: 3, length: 5, length: 3],
        children: [
          box(focus_proxy: :save, padding: {0, 2}, child: button("Save", focusable: :save)),
          box(
            focus_proxy: :log,
            child:
              viewport(
                focusable: :log,
                offset: m.offset,
                content_height: 20,
                child: text(Enum.map_join(1..20, "\n", &"line #{&1}"))
              )
          ),
          box(focus_proxy: :other, handle_mouse: false, child: text("x", focusable: :other))
        ]
      )
    end
  end

  describe "a box with focus_proxy" do
    setup do
      h = Harlock.Test.start_app(PaneApp, nil, rows: 11, cols: 30, mouse: true)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "a click on its border or padding focuses the child, and only focuses", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 1, 4)
      assert Harlock.Test.focused(h) == :log

      # Padding beside the button: focus moves, the button is not pressed.
      Harlock.Test.send_mouse(h, :press, :left, 2, 2)
      assert Harlock.Test.focused(h) == :save
      assert model(h).saves == 0

      # The button itself still presses.
      Harlock.Test.send_mouse(h, :press, :left, 5, 2)
      assert model(h).saves == 1
      assert model(h).raw == []
    end

    test "the wheel over its border scrolls the child", %{h: h} do
      Harlock.Test.send_mouse(h, :wheel_down, nil, 1, 6)
      assert model(h).offset == 3
    end

    test "handle_mouse: false on the box leaves its border to the app", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 1, 9)
      assert Harlock.Test.focused(h) == :save
      assert [{:mouse, :press, :left, 1, 9, []}] = model(h).raw
    end
  end

  defmodule TextAreaApp do
    use Harlock.App

    def init({value, cursor, wrap}), do: %{value: value, cursor: cursor, wrap: wrap}

    def update({:harlock_edit, :notes, {value, cursor}}, m),
      do: %{m | value: value, cursor: cursor}

    def update(_, m), do: m

    # Row 1 is a line of text; the textarea is rows 2–4, columns 3–12.
    def view(m) do
      vbox(
        constraints: [length: 1, length: 3, fill: 1],
        children: [
          text("above"),
          hbox(
            constraints: [length: 2, length: 10, fill: 1],
            children: [
              spacer(),
              textarea(focusable: :notes, value: m.value, cursor: m.cursor, wrap: m.wrap),
              spacer()
            ]
          ),
          spacer()
        ]
      )
    end
  end

  describe "a click in a textarea" do
    defp start_area(value, cursor, wrap \\ false),
      do:
        Harlock.Test.start_app(TextAreaApp, {value, cursor, wrap}, rows: 6, cols: 20, mouse: true)

    test "places the cursor at the clicked line and column", %{} do
      h = start_area("first\nsecond line\nthird", 0)

      # Row 3 is the second line; column 5 is two cells into the area.
      Harlock.Test.send_mouse(h, :press, :left, 5, 3)
      assert Harlock.Test.model(h).cursor == String.length("first\n") + 2

      # Past the end of a line: the end of that line.
      Harlock.Test.send_mouse(h, :press, :left, 11, 2)
      assert Harlock.Test.model(h).cursor == String.length("first")
      Harlock.Test.stop(h)
    end

    test "counts display rows when wrapping and scrolled", %{} do
      # Ten-cell rows: "aaaaaaaaaa" "bbbbbbbbbb" on one logical line, then more
      # lines, with the cursor at the end so the area has scrolled down.
      value = String.duplicate("a", 10) <> String.duplicate("b", 10) <> "\nc\nd\ne"
      h = start_area(value, String.length(value), true)

      # Five display rows, three visible: the top one drawn is "c" (row 2).
      Harlock.Test.send_mouse(h, :press, :left, 3, 2)
      assert Harlock.Test.model(h).cursor == 21
      Harlock.Test.stop(h)
    end

    test "a click ends a run of vertical motion", %{} do
      h = start_area("abcdef\nab\nabcdef", 5)

      # ↓ from column 5 onto a two-column line remembers column 5 as the goal.
      Harlock.Test.send_key(h, :down)
      # Clicking column 1 of that line replaces the goal; ↓ then keeps column 1.
      Harlock.Test.send_mouse(h, :press, :left, 4, 3)
      Harlock.Test.send_key(h, :down)

      assert Harlock.Test.model(h).cursor == String.length("abcdef\nab\n") + 1
      Harlock.Test.stop(h)
    end
  end

  defmodule ItemsApp do
    use Harlock.App

    # Records every routed message, so tests can check both what arrived and in
    # which order.
    def init(_),
      do: %{log: [], open: false, highlight: :red, value: :red, name: "héllo日本", cursor: 0}

    def update({:harlock_select, :colour, id} = msg, m),
      do: %{m | log: m.log ++ [msg], highlight: id}

    def update({:harlock_submit, :colour} = msg, m) do
      m = %{m | log: m.log ++ [msg]}
      if m.open, do: %{m | open: false, value: m.highlight}, else: %{m | open: true}
    end

    def update({:harlock_edit, :name, {v, c}} = msg, m),
      do: %{m | log: m.log ++ [msg], name: v, cursor: c}

    def update({tag, _, _} = msg, m) when tag in [:harlock_select, :harlock_toggle],
      do: %{m | log: m.log ++ [msg]}

    def update({:harlock_submit, _} = msg, m), do: %{m | log: m.log ++ [msg]}
    def update(_, m), do: m

    def view(m) do
      vbox(
        constraints: [length: 2, length: 2, length: 1, length: 2, length: 1, length: 1, fill: 1],
        children: [
          table(
            focusable: :rows,
            columns: [column(width: {:fill, 1}, render: &to_string/1)],
            rows: [:alpha, :beta],
            row_id: & &1,
            focused_row: :alpha,
            show_header: false
          ),
          menu(focusable: :actions, items: [{:open, "Open"}, {:quit, "Quit"}], active: :open),
          tabs(focusable: :nav, items: [{:one, "One"}, {:two, "Two"}], active: :one),
          tree(
            focusable: :files,
            nodes: [%{id: :dir, label: "dir", children: [%{id: :f, label: "f", children: []}]}],
            expanded: MapSet.new([:dir]),
            focused: :dir
          ),
          text_input(focusable: :name, value: m.name, cursor: m.cursor),
          select(
            focusable: :colour,
            items: [{:red, "Red"}, {:green, "Green"}],
            value: m.value,
            highlight: m.highlight,
            open: m.open
          ),
          text("")
        ]
      )
    end
  end

  describe "clicks on items inside widgets" do
    setup do
      h = Harlock.Test.start_app(ItemsApp, nil, rows: 14, cols: 30, mouse: true)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    defp log(h), do: Harlock.Test.model(h).log

    test "a table row selects it", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 5, 2)
      assert log(h) == [{:harlock_select, :rows, :beta}]
      assert Harlock.Test.focused(h) == :rows
    end

    test "a menu item is selected and activated, in that order", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 2, 4)
      assert log(h) == [{:harlock_select, :actions, :quit}, {:harlock_submit, :actions}]
    end

    test "a tab selects it", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 10, 5)
      assert log(h) == [{:harlock_select, :nav, :two}]
    end

    test "a tree's marker toggles the node; the rest of the row selects it", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 1, 6)
      assert log(h) == [{:harlock_toggle, :files, :dir}]

      Harlock.Test.send_mouse(h, :press, :left, 7, 7)
      assert List.last(log(h)) == {:harlock_select, :files, :f}
    end

    test "a click in a text input moves the cursor to that column, by grapheme", %{h: h} do
      # "héllo日本": columns 0-4 are h é l l o, then 日 covers 5-6 and 本 7-8.
      Harlock.Test.send_mouse(h, :press, :left, 3, 8)
      assert Harlock.Test.model(h).cursor == 2

      Harlock.Test.send_mouse(h, :press, :left, 8, 8)
      assert Harlock.Test.model(h).cursor == 6

      Harlock.Test.send_mouse(h, :press, :left, 25, 8)
      assert Harlock.Test.model(h).cursor == 7

      # Clicking where the cursor already is changes nothing.
      Harlock.Test.send_mouse(h, :press, :left, 25, 8)
      assert length(log(h)) == 3
    end

    test "a select opens from its control and commits a clicked choice", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 2, 9)
      assert Harlock.Test.model(h).open == true

      # The list opens below the control: border on row 10, choices from row 11.
      Harlock.Test.send_mouse(h, :press, :left, 3, 12)

      assert Harlock.Test.model(h).value == :green
      assert Harlock.Test.model(h).open == false

      assert log(h) == [
               {:harlock_submit, :colour},
               {:harlock_select, :colour, :green},
               {:harlock_submit, :colour}
             ]
    end
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
