defmodule Harlock.Examples.SysmonTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "sysmon.exs"]))

  setup do
    h = Harlock.Test.start_app(Sysmon, nil, [rows: 22, cols: 100] ++ Sysmon.run_opts())
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

  defp model(h), do: Harlock.Test.model(h)

  test "the table has focus at start, and a click or the wheel moves the cursor", %{h: h} do
    assert Harlock.Test.focused(h) == :process_table

    # Paused, so a refresh cannot re-sort the rows between the steps.
    click(h, "[x] Live", 1)
    third = Enum.at(model(h).processes, 2).pid_str
    click(h, third)
    assert model(h).cursor == third

    {col, row} = position_of(h, third)
    Harlock.Test.send_mouse(h, :wheel_down, nil, col, row)
    assert model(h).cursor == Enum.at(model(h).processes, 3).pid_str
  end

  test "the sort radio group re-sorts the table", %{h: h} do
    click(h, "( ) reductions", 1)

    assert model(h).sort == :reductions
    reductions = Enum.map(model(h).processes, & &1.reductions)
    assert reductions == Enum.sort(reductions, :desc)
    assert Harlock.Test.render(h) =~ "sorted by reductions"
  end

  test "unticking Live stops the refresh", %{h: h} do
    click(h, "[x] Live", 1)

    refute model(h).live
    assert Sysmon.subs(model(h)) == []
    assert Harlock.Test.render(h) =~ "paused"
  end

  test "the quit dialog's buttons cancel and quit", %{h: h} do
    Harlock.Test.send_key(h, {:char, ?q})
    assert Harlock.Test.focused(h) == :quit_yes

    click(h, "[ Cancel ]", 2)
    assert model(h).dialog == nil
    assert Harlock.Test.focused(h) == :process_table

    Harlock.Test.send_key(h, {:char, ?q})
    Harlock.Test.send_key(h, :enter)
    assert Harlock.Test.quit?(h)
  end

  test "the help dialog closes from its button", %{h: h} do
    Harlock.Test.send_key(h, {:char, ??})
    assert Harlock.Test.render(h) =~ "this help"

    click(h, "[ Close ]", 2)
    assert model(h).dialog == nil
  end
end
