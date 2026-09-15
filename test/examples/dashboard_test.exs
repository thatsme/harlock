defmodule Harlock.Examples.DashboardTest do
  # async: false — the dashboard's logger subscription is a global :logger
  # handler, and would pick up lines other tests log while this one runs.
  use ExUnit.Case, async: false

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "dashboard.exs"]))

  # Started paused, so no workload runs and every number on screen comes from
  # the messages a test sends.
  setup do
    h =
      Harlock.Test.start_app(
        Dashboard,
        [running: false],
        [rows: 24, cols: 90] ++ Dashboard.run_opts()
      )

    on_exit(fn -> Harlock.Test.stop(h) end)
    {:ok, h: h}
  end

  # 1-indexed {col, row} of the first occurrence of `needle` on screen, as a
  # terminal would report a click on it.
  defp position_of(h, needle) do
    h
    |> Harlock.Test.render()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, row} ->
      case :binary.match(line, needle) do
        {byte, _} -> {String.length(binary_part(line, 0, byte)) + 1, row}
        :nomatch -> nil
      end
    end) || flunk("#{inspect(needle)} is not on screen:\n#{Harlock.Test.render(h)}")
  end

  defp click(h, needle, offset \\ 0) do
    {col, row} = position_of(h, needle)
    Harlock.Test.send_mouse(h, :press, :left, col + offset, row)
  end

  defp log(h, level, text),
    do: Harlock.Test.send_event(h, {:log, %{level: level, msg: {:string, text}, meta: %{}}})

  defp model(h), do: Harlock.Test.model(h)

  test "job durations feed the stats line", %{h: h} do
    assert Harlock.Test.render(h) =~ "no samples yet"

    Harlock.Test.send_event(h, {:job, 3_000})
    Harlock.Test.send_event(h, {:job, 9_000})

    screen = Harlock.Test.render(h)
    assert screen =~ "jobs 2   slow 1   last 9000µs   mean 6000µs"
    assert screen =~ "min 3000µs   max 9000µs"
  end

  test "log lines arrive newest first, with their level", %{h: h} do
    assert Harlock.Test.render(h) =~ "waiting for log lines"

    log(h, :info, "first line")
    log(h, :warning, "second line")

    screen = Harlock.Test.render(h)
    assert screen =~ ~r/warning\s+second line.*\n.*info\s+first line/
    assert screen =~ "2 lines"
  end

  test "the wheel scrolls the log, and a new line keeps the scrolled view still", %{h: h} do
    for n <- 1..40, do: log(h, :info, "line #{n}")

    {col, row} = position_of(h, "line 40")
    Harlock.Test.send_mouse(h, :wheel_down, nil, col, row)
    assert model(h).log_offset == 3
    refute Harlock.Test.render(h) =~ "line 40"

    before = position_of(h, "line 37")

    log(h, :info, "line 41")
    assert model(h).log_offset == 4
    assert position_of(h, "line 37") == before
    refute Harlock.Test.render(h) =~ "line 41"
  end

  test "Clear empties the history, by click and by key", %{h: h} do
    Harlock.Test.send_event(h, {:job, 3_000})
    log(h, :info, "something")
    click(h, "[ Clear ]", 2)
    assert %{durations: [], logs: [], jobs: 0} = model(h)

    Harlock.Test.send_event(h, {:job, 3_000})
    Harlock.Test.send_key(h, {:char, ?c})
    assert %{durations: [], jobs: 0} = model(h)
  end

  # Resuming starts the real workload, so this checks only the switch itself.
  test "Pause and Resume work by click and by key", %{h: h} do
    click(h, "[ Resume ]", 2)
    assert model(h).running
    assert Harlock.Test.render(h) =~ "[ Pause ]"

    Harlock.Test.send_key(h, {:char, ?p})
    refute model(h).running
    assert Harlock.Test.render(h) =~ "[ Resume ]"
  end

  test "the load radio group sets the workload size", %{h: h} do
    click(h, "( ) heavy", 1)
    assert model(h).load == :heavy

    Harlock.Test.send_key(h, :left)
    assert model(h).load == :normal
  end
end
