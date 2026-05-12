defmodule Harlock.Element.TableTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer

  defp row(frame, row), do: row_to_string(frame, row)

  defp row_to_string(frame, row) do
    cols = frame.buffer.cols

    0..(cols - 1)
    |> Enum.map(fn col ->
      case Buffer.get(frame.buffer, row, col).char do
        nil -> ?\s
        c -> c
      end
    end)
    |> :unicode.characters_to_binary()
  end

  defp simple_table(rows, focused \\ nil) do
    table(
      columns: [
        column(title: "ID", width: {:length, 3}, align: :right, render: & &1.id),
        column(title: "Name", width: {:fill, 1}, render: & &1.name)
      ],
      rows: rows,
      row_id: & &1.id,
      focused_row: focused
    )
  end

  describe "required options" do
    test "raises without :row_id" do
      assert_raise ArgumentError, ~r/row_id/, fn ->
        table(columns: [], rows: [])
      end
    end

    test "raises without :columns" do
      assert_raise ArgumentError, ~r/columns/, fn ->
        table(rows: [], row_id: & &1)
      end
    end

    test "raises without :rows" do
      assert_raise ArgumentError, ~r/rows/, fn ->
        table(columns: [], row_id: & &1)
      end
    end
  end

  describe "header" do
    test "renders titles when show_header is true (default)" do
      rows = [%{id: 1, name: "a"}]
      frame = Renderer.render(simple_table(rows), 3, 10)
      assert row(frame, 0) =~ "ID"
      assert row(frame, 0) =~ "Name"
    end

    test "omitted when show_header is false" do
      rows = [%{id: 1, name: "a"}]

      t =
        table(
          columns: [column(title: "X", width: {:fill, 1}, render: & &1.name)],
          rows: rows,
          row_id: & &1.id,
          show_header: false
        )

      frame = Renderer.render(t, 1, 5)
      assert row(frame, 0) == "a    "
    end
  end

  describe "alignment" do
    test "right-aligned column pads on the left" do
      rows = [%{id: 1, name: "a"}]
      frame = Renderer.render(simple_table(rows), 2, 8)
      # ID column is width 3, right-aligned. "1" rendered as "  1"
      assert String.slice(row(frame, 1), 0, 3) == "  1"
    end

    test "left-aligned column pads on the right" do
      rows = [%{id: 1, name: "x"}]
      frame = Renderer.render(simple_table(rows), 2, 8)
      # Name starts at col 3 (after the ID column), left-aligned in 5 cells
      assert String.slice(row(frame, 1), 3, 5) == "x    "
    end
  end

  describe "scrolling" do
    test "shows all rows when they fit" do
      rows = for i <- 1..3, do: %{id: i, name: "r#{i}"}
      frame = Renderer.render(simple_table(rows), 4, 8)
      # header is row 0; rows at 1, 2, 3
      assert row(frame, 1) =~ "1"
      assert row(frame, 2) =~ "2"
      assert row(frame, 3) =~ "3"
    end

    test "centers around focused row when overflowing" do
      rows = for i <- 1..10, do: %{id: i, name: "r#{i}"}
      # body_height = 3 (4 rows total - 1 header). Focused on id 5 (idx 4).
      # start = clamp(4 - div(3,2), 0, 10 - 3) = clamp(3, 0, 7) = 3.
      # Visible = idx 3, 4, 5 → ids 4, 5 (focused), 6.
      frame = Renderer.render(simple_table(rows, 5), 4, 8)
      assert row(frame, 1) =~ "4"
      assert row(frame, 2) =~ "5"
      assert row(frame, 3) =~ "6"
    end
  end

  describe "list as degenerate table" do
    test "single column, no header, defaults" do
      tree = list(["a", "b", "c"])
      frame = Renderer.render(tree, 3, 5)
      assert row(frame, 0) =~ "a"
      assert row(frame, 1) =~ "b"
      assert row(frame, 2) =~ "c"
    end
  end
end
