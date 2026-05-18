defmodule Harlock.Examples.ShowcaseTest do
  use ExUnit.Case, async: false

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "showcase.exs"]))

  setup do
    h = Harlock.Test.start_app(ShowcaseApp, nil, rows: 30, cols: 100)
    on_exit(fn -> Harlock.Test.stop(h) end)
    {:ok, h: h}
  end

  test "boots and shows the Logs tab", %{h: h} do
    out = Harlock.Test.render(h)
    assert out =~ "Harlock v0.4 Showcase"
    assert out =~ "1. Logs"
    assert out =~ "2. Form"
    assert out =~ "3. Widgets"
    assert out =~ "4. Keys"
  end

  test "Shift-Right cycles to the next tab", %{h: h} do
    Harlock.Test.send_key(h, :right, [:shift])
    out = Harlock.Test.render(h)
    assert out =~ "14 fields"
  end

  test "digit keys switch tabs (outside form)", %{h: h} do
    Harlock.Test.send_key(h, {:char, ?3})
    out = Harlock.Test.render(h)
    assert out =~ "Deployment progress"

    Harlock.Test.send_key(h, {:char, ?4})
    out = Harlock.Test.render(h)
    assert out =~ "press anything"
  end

  test "Logs tab scrolls with arrow keys", %{h: h} do
    out_before = Harlock.Test.render(h)
    assert out_before =~ "  2  ERROR"

    Enum.each(1..40, fn _ -> Harlock.Test.send_key(h, :down) end)
    out_after = Harlock.Test.render(h)

    refute out_after =~ "  2  ERROR"
    assert out_after =~ "offset: 40"
  end

  test "Keys tab captures modified arrow events", %{h: h} do
    Harlock.Test.send_key(h, {:char, ?4})
    Harlock.Test.send_key(h, :up, [:ctrl])
    Harlock.Test.send_key(h, :right, [:shift, :alt])

    out = Harlock.Test.render(h)
    assert out =~ "ctrl + up"
    assert out =~ "shift + alt + right"
  end
end
