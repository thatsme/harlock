defmodule Harlock.Examples.OverviewTest do
  use ExUnit.Case, async: false

  # Loading the example here is the compile-rot guard for the README
  # snippet: if examples/overview.exs stops compiling, this test file
  # fails to load and CI goes red.
  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "overview.exs"]))

  setup do
    h = Harlock.Test.start_app(Overview, nil, rows: 24, cols: 80)
    on_exit(fn -> Harlock.Test.stop(h) end)
    {:ok, h: h}
  end

  test "boots and shows both panels with the first task selected", %{h: h} do
    out = Harlock.Test.render(h)
    assert out =~ "Tasks"
    assert out =~ "Log"
    assert out =~ "compile"
    assert out =~ "[1] event line 1"
  end

  test "Tab cycles focus and the focused panel handles its own keys", %{h: h} do
    # Initial focus is on Tasks; Down moves selection from row 1 to row 2.
    Harlock.Test.send_key(h, :down)
    assert Harlock.Test.render(h) =~ "test"

    # Tab moves focus to the Log panel; Down now scrolls instead.
    Harlock.Test.send_key(h, :tab)
    Enum.each(1..5, fn _ -> Harlock.Test.send_key(h, :down) end)
    out = Harlock.Test.render(h)
    refute out =~ "[1] event line 1"
    assert out =~ "[6] event line 6"
  end

  test "r triggers a Cmd that prepends refreshed log lines", %{h: h} do
    refute Harlock.Test.render(h) =~ "[refresh]"
    Harlock.Test.send_key(h, {:char, ?r})
    # Cmd runs in a Task; give it a brief moment to complete and the
    # frame to re-render.
    Process.sleep(50)
    assert Harlock.Test.render(h) =~ "[refresh] new line 1"
  end
end
