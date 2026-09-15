defmodule Harlock.CheckListTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer

  defp row_chars(frame, row, cols) do
    for c <- 0..(cols - 1)//1, into: "" do
      case Buffer.get(frame.buffer, row, c).char do
        nil -> " "
        cp when is_integer(cp) -> <<cp::utf8>>
        bin -> bin
      end
    end
  end

  describe "list/2 with marker: :checkbox" do
    test "draws [x] for items in the set and [ ] for the rest" do
      el = list([:ham, :olives], selection: {:multi, MapSet.new([:olives])}, marker: :checkbox)
      frame = Renderer.render(el, 2, 12)

      assert row_chars(frame, 0, 12) == "[ ] ham     "
      assert row_chars(frame, 1, 12) == "[x] olives  "
    end

    test "puts the marker before a custom render, keyed by row_id" do
      el =
        list([%{id: 1, name: "Ham"}],
          row_id: & &1.id,
          render: & &1.name,
          selection: {:multi, MapSet.new([1])},
          marker: :checkbox
        )

      assert row_chars(Renderer.render(el, 1, 8), 0, 8) == "[x] Ham "
    end

    test "requires a {:multi, set} selection, and knows only :checkbox" do
      assert_raise ArgumentError, ~r/requires selection/, fn ->
        list([:a], selection: {:single, :a}, marker: :checkbox)
      end

      assert_raise ArgumentError, ~r/:marker must be :checkbox/, fn ->
        list([:a], selection: {:multi, MapSet.new()}, marker: :star)
      end
    end
  end

  defmodule App do
    use Harlock.App

    def init(_), do: %{focused: :ham, chosen: MapSet.new(), picked: :red, raw: []}

    def update({:harlock_select, :toppings, id}, m), do: %{m | focused: id}

    def update({:harlock_toggle, :toppings, id}, m) do
      chosen = if id in m.chosen, do: MapSet.delete(m.chosen, id), else: MapSet.put(m.chosen, id)
      %{m | chosen: chosen}
    end

    def update({:harlock_select, :colour, id}, m), do: %{m | picked: id}
    def update({:key, _, _} = ev, m), do: %{m | raw: m.raw ++ [ev]}
    def update(_, m), do: m

    # Rows 1–3: a check list. Rows 4–5: a list that picks one.
    def view(m) do
      vbox(
        constraints: [length: 3, length: 2],
        children: [
          list([:ham, :olives, :basil],
            focusable: :toppings,
            focused_row: m.focused,
            selection: {:multi, m.chosen},
            marker: :checkbox
          ),
          list([:red, :green], focusable: :colour, focused_row: m.picked)
        ]
      )
    end
  end

  describe "routing" do
    setup do
      h = Harlock.Test.start_app(App, nil, rows: 6, cols: 20, mouse: true)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "Space toggles the focused item; arrows still move the focus", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?\s})
      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, {:char, ?\s})

      assert Harlock.Test.model(h).chosen == MapSet.new([:ham, :basil])
      assert Harlock.Test.render(h) =~ "[x] basil"

      Harlock.Test.send_key(h, {:char, ?\s})
      assert Harlock.Test.model(h).chosen == MapSet.new([:ham])
      assert Harlock.Test.model(h).raw == []
    end

    test "a click on a checkbox item focuses it and toggles it", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 6, 2)

      assert Harlock.Test.model(h).focused == :olives
      assert Harlock.Test.model(h).chosen == MapSet.new([:olives])
    end

    test "a list without {:multi, set} picks one: a click selects, Space passes", %{h: h} do
      Harlock.Test.send_mouse(h, :press, :left, 3, 5)
      assert Harlock.Test.model(h).picked == :green
      assert Harlock.Test.focused(h) == :colour

      Harlock.Test.send_key(h, {:char, ?\s})
      assert Harlock.Test.model(h).raw == [{:key, {:char, ?\s}, []}]
    end
  end
end
