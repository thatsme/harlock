defmodule Harlock.Examples.NodesTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "nodes.exs"]))

  setup do
    h = Harlock.Test.start_app(Nodes, nil, [rows: 24, cols: 100] ++ Nodes.run_opts())
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

  # Supervisor children load through a Cmd, so they arrive later.
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  test "the process list is filled from the start, memory included", %{h: h} do
    screen = Harlock.Test.render(h)

    assert screen =~ "#PID<0.0.0>"
    assert screen =~ ~r/processes \(\d+\)/
    refute screen =~ "mem 0 MB"
  end

  test "a click on a process shows its details", %{h: h} do
    assert Harlock.Test.render(h) =~ "click a process"

    click(h, "#PID<0.0.0>")
    assert Harlock.Test.model(h).selected == :erlang.list_to_pid(~c"<0.0.0>")

    assert Harlock.Test.render(h) =~ ~r/#PID<0\.0\.0>\s+status \w+\s+in /
  end

  test "the wheel scrolls the process list", %{h: h} do
    {col, row} = position_of(h, "#PID<0.0.0>")
    Harlock.Test.send_mouse(h, :wheel_down, nil, col, row)

    assert Harlock.Test.model(h).proc_offset == 1
    refute Harlock.Test.render(h) =~ "#PID<0.0.0>"
  end

  test "tabs switch by click and by digit; the supervisors tab loads its roots", %{h: h} do
    click(h, "2 supervisors", 1)
    assert Harlock.Test.model(h).tab == :supervisors
    assert Harlock.Test.render(h) =~ "kernel_sup"

    Harlock.Test.send_key(h, {:char, ?3})
    assert Harlock.Test.render(h) =~ ~r/process_count\s+\d+ \/ \d+/

    Harlock.Test.send_key(h, {:char, ?1})
    assert Harlock.Test.model(h).tab == :processes
  end

  test "a click on a supervisor's marker loads and shows its children", %{h: h} do
    Harlock.Test.send_key(h, {:char, ?2})
    click(h, "▸ kernel_sup")

    assert eventually(fn -> Harlock.Test.render(h) =~ ":kernel_config" end)
  end
end
