defmodule Harlock.OverlayTest do
  use ExUnit.Case, async: true

  defmodule App do
    use Harlock.App

    def init(_), do: %{dialog: nil}

    def update({:key, {:char, ??}, []}, m), do: %{m | dialog: :help}
    def update({:key, :escape, []}, m), do: %{m | dialog: nil}
    def update({:key, {:char, ?q}, []}, _), do: :quit
    def update(_, m), do: m

    def view(m) do
      base =
        vbox(
          children: [
            text("a", focusable: :outer_a),
            text("b", focusable: :outer_b),
            text("c", focusable: :outer_c)
          ]
        )

      case m.dialog do
        nil ->
          base

        :help ->
          overlay(
            child: base,
            over:
              vbox(
                focus_trap: true,
                children: [
                  text("h1", focusable: :help_1),
                  text("h2", focusable: :help_2)
                ]
              ),
            width: 10,
            height: 5,
            anchor: :center,
            focus_trap: true
          )
      end
    end
  end

  test "focus starts on first outer element" do
    h = Harlock.Test.start_app(App, nil, rows: 8, cols: 20)
    assert Harlock.Test.focused(h) == :outer_a
    Harlock.Test.stop(h)
  end

  test "Tab cycles through outer focusables when no dialog" do
    h = Harlock.Test.start_app(App, nil, rows: 8, cols: 20)
    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :outer_b
    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :outer_c
    Harlock.Test.stop(h)
  end

  test "opening dialog stashes outer focus and moves into trap" do
    h = Harlock.Test.start_app(App, nil, rows: 8, cols: 20)
    # advance focus to :outer_b before opening dialog
    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :outer_b

    Harlock.Test.send_key(h, {:char, ??})
    assert Harlock.Test.focused(h) == :help_1

    Harlock.Test.stop(h)
  end

  test "Tab inside trap wraps within trap subtree" do
    h = Harlock.Test.start_app(App, nil, rows: 8, cols: 20)
    Harlock.Test.send_key(h, {:char, ??})

    assert Harlock.Test.focused(h) == :help_1
    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :help_2
    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :help_1

    Harlock.Test.stop(h)
  end

  test "closing dialog restores prior focus" do
    h = Harlock.Test.start_app(App, nil, rows: 8, cols: 20)
    Harlock.Test.send_key(h, :tab)
    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :outer_c

    Harlock.Test.send_key(h, {:char, ??})
    assert Harlock.Test.focused(h) == :help_1

    Harlock.Test.send_key(h, :escape)
    assert Harlock.Test.focused(h) == :outer_c

    Harlock.Test.stop(h)
  end
end
