defmodule Harlock.Examples.OverviewTest do
  use ExUnit.Case, async: false

  # Loading the example here is the compile-rot guard for the README
  # snippet: if examples/overview.exs stops compiling, this test file
  # fails to load and CI goes red.
  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "overview.exs"]))

  @root Path.join([__DIR__, "..", ".."])

  # Started as the README starts it.
  setup do
    h = Harlock.Test.start_app(Overview, nil, rows: 24, cols: 80, mouse: true)
    on_exit(fn -> Harlock.Test.stop(h) end)
    {:ok, h: h}
  end

  test "the README quotes the example's module and starts it the same way" do
    module = fn text ->
      [snippet] = Regex.run(~r/^defmodule Overview do\n.*?^end$/ms, text)
      snippet
    end

    readme = File.read!(Path.join(@root, "README.md"))
    example = File.read!(Path.join([@root, "examples", "overview.exs"]))

    assert module.(readme) == module.(example)
    assert readme =~ "\nHarlock.run(Overview, nil, mouse: true)\n"
    assert example =~ "Harlock.run(Overview, nil, mouse: true)"
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

  test "a click selects a task and the wheel scrolls the log", %{h: h} do
    lines = h |> Harlock.Test.render() |> String.split("\n")
    row = Enum.find_index(lines, &(&1 =~ "dialyzer")) + 1

    Harlock.Test.send_mouse(h, :press, :left, 5, row)
    assert Harlock.Test.model(h).selected == 3

    Harlock.Test.send_mouse(h, :wheel_down, nil, 50, 5)
    assert Harlock.Test.model(h).log_offset == 3
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
