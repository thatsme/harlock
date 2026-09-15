defmodule Harlock.Examples.ExplorerTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "explorer.exs"]))

  defp start, do: Harlock.Test.start_app(Explorer, nil, rows: 20, cols: 80, mouse: true)

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

  # The deps subtree loads through a Cmd, so its result arrives later.
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp model(h), do: Harlock.Test.model(h)

  test "the details pane follows the selected node" do
    h = start()
    assert Harlock.Test.render(h) =~ "directory, 3 items"

    Harlock.Test.send_key(h, :down)
    Harlock.Test.send_key(h, :down)
    assert Harlock.Test.render(h) =~ "README.md"
    assert Harlock.Test.render(h) =~ ~r/Kind\s+file/
    Harlock.Test.stop(h)
  end

  test "clicking a marker loads deps; clicking a row selects it" do
    h = start()
    click(h, "▸ deps")
    assert eventually(fn -> Harlock.Test.render(h) =~ "telemetry" end)

    click(h, "telemetry")
    assert model(h).node == :telemetry
    assert Harlock.Test.focused(h) == :files
    Harlock.Test.stop(h)
  end

  test "the filter opens and commits by mouse" do
    h = start()
    click(h, "All files")
    assert model(h).filter_open

    click(h, "Docs only")
    refute model(h).filter_open
    assert model(h).filter == :docs
    refute Harlock.Test.render(h) =~ "my_app.ex"
    Harlock.Test.stop(h)
  end

  test "an open filter closes when Tab moves focus away" do
    h = start()
    Harlock.Test.send_key(h, :tab)
    Harlock.Test.send_key(h, :enter)
    Harlock.Test.send_key(h, :down)
    assert model(h).filter_open

    Harlock.Test.send_key(h, :tab)
    assert Harlock.Test.focused(h) == :actions
    refute model(h).filter_open
    # The highlight goes back to the committed value: leaving is not choosing.
    assert model(h).filter_highlight == :all
    assert Harlock.Test.render(h) =~ "Expand all"
    Harlock.Test.stop(h)
  end

  test "an open filter closes when a click lands elsewhere" do
    h = start()
    click(h, "All files")
    assert model(h).filter_open

    click(h, "README.md")
    refute model(h).filter_open
    assert model(h).node == :readme
    Harlock.Test.stop(h)
  end

  test "clicking an action runs it, and a pane's border focuses its widget" do
    h = start()
    click(h, "Expand all")
    assert Harlock.Test.focused(h) == :actions
    assert model(h).status == "Expanded all"

    click(h, "╭ Files")
    assert Harlock.Test.focused(h) == :files
    Harlock.Test.stop(h)
  end
end
