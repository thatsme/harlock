defmodule Harlock.Element.TableWindowTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer

  defp row_text(frame, row, width) do
    for col <- 0..(width - 1), into: "" do
      case Buffer.get(frame.buffer, row, col).char do
        nil -> " "
        :continuation -> ""
        ch -> <<ch::utf8>>
      end
    end
    |> String.trim_trailing()
  end

  defp body(frame, rows, width) do
    # row 0 is the header
    for(r <- 1..(rows - 1), do: row_text(frame, r, width)) |> Enum.reject(&(&1 == ""))
  end

  defp cols, do: [column(title: "name", width: {:fill, 1}, render: & &1.name)]

  defp windowed(opts) do
    table(Keyword.merge([columns: cols(), row_id: & &1.id], opts))
  end

  # Records what the window function was asked for, so a test can assert the
  # table never requested more than it could draw.
  defp recording_fetch(agent) do
    fn offset, limit ->
      Agent.update(agent, &[{offset, limit} | &1])
      for i <- offset..(offset + limit - 1), do: %{id: i, name: "row #{i}"}
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {:ok, agent: agent}
  end

  describe "window function" do
    test "renders the rows the function returns", %{agent: agent} do
      el = windowed(rows: recording_fetch(agent), offset: 0)
      frame = Renderer.render(el, 4, 20)

      assert body(frame, 4, 20) == ["row 0", "row 1", "row 2"]
    end

    test ":offset selects which window is fetched", %{agent: agent} do
      el = windowed(rows: recording_fetch(agent), offset: 100)
      frame = Renderer.render(el, 4, 20)

      assert body(frame, 4, 20) == ["row 100", "row 101", "row 102"]
    end

    test "asks only for what the body can draw", %{agent: agent} do
      # 10 rows tall, one taken by the header
      Renderer.render(windowed(rows: recording_fetch(agent), offset: 5), 10, 20)

      assert Agent.get(agent, & &1) == [{5, 9}]
    end

    test "a header-less table asks for the full height", %{agent: agent} do
      Renderer.render(windowed(rows: recording_fetch(agent), show_header: false), 10, 20)

      assert Agent.get(agent, & &1) == [{0, 10}]
    end

    test "a negative offset clamps to zero", %{agent: agent} do
      Renderer.render(windowed(rows: recording_fetch(agent), offset: -5), 4, 20)

      assert Agent.get(agent, & &1) == [{0, 3}]
    end

    test "extra rows beyond the window are dropped rather than overflowing" do
      # a sloppy source returning more than asked must not draw past its region
      greedy = fn _offset, _limit -> for i <- 1..50, do: %{id: i, name: "row #{i}"} end
      frame = Renderer.render(windowed(rows: greedy), 4, 20)

      assert length(body(frame, 4, 20)) == 3
    end

    test "returning fewer rows than asked simply ends the table" do
      short = fn _offset, _limit -> [%{id: 1, name: "only"}] end
      frame = Renderer.render(windowed(rows: short), 6, 20)

      assert body(frame, 6, 20) == ["only"]
    end

    test "an empty window renders just the header" do
      empty = fn _offset, _limit -> [] end
      frame = Renderer.render(windowed(rows: empty), 5, 20)

      assert body(frame, 5, 20) == []
      assert row_text(frame, 0, 20) =~ "name"
    end

    test "is never asked for anything when there is no body height" do
      {:ok, agent} = Agent.start_link(fn -> [] end)
      # one row tall, entirely consumed by the header
      Renderer.render(windowed(rows: recording_fetch(agent)), 1, 20)

      assert Agent.get(agent, & &1) == []
    end

    test ":focused_row still styles a row inside the window", %{agent: agent} do
      el = windowed(rows: recording_fetch(agent), offset: 10, focused_row: 11)
      frame = Renderer.render(el, 4, 20)

      focused = Buffer.get(frame.buffer, 2, 0).style_id
      other = Buffer.get(frame.buffer, 1, 0).style_id

      refute focused == other
    end
  end

  describe "enumerable rows stay unchanged" do
    test "a list is still auto-centred on the focused row" do
      rows = for i <- 1..100, do: %{id: i, name: "row #{i}"}
      el = table(columns: cols(), row_id: & &1.id, rows: rows, focused_row: 50)

      frame = Renderer.render(el, 6, 20)
      drawn = body(frame, 6, 20)

      # centred around 50 rather than starting at the top
      assert "row 50" in drawn
      refute "row 1" in drawn
    end

    test "a short list renders from the top" do
      rows = for i <- 1..3, do: %{id: i, name: "row #{i}"}
      el = table(columns: cols(), row_id: & &1.id, rows: rows)

      assert body(Renderer.render(el, 6, 20), 6, 20) == ["row 1", "row 2", "row 3"]
    end

    test "a lazy stream is still materialised, so it must be finite" do
      rows = Stream.map(1..5, &%{id: &1, name: "row #{&1}"})
      el = table(columns: cols(), row_id: & &1.id, rows: rows)

      assert body(Renderer.render(el, 4, 20), 4, 20) == ["row 1", "row 2", "row 3"]
    end
  end
end
