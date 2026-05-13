defmodule Harlock.Tabs do
  @moduledoc """
  Key-event helper for the `Harlock.Elements.tabs/1` widget.

  The widget is a dumb renderer — the app holds the active tab id in
  its model. When the tabs element has focus, route key events through
  `apply_key/3` to compute the next active id:

      def update({:key, _, _} = event, %{tab: active} = model) do
        case Harlock.Focus.current() do
          :tabs ->
            case Harlock.Tabs.apply_key(event, active, [{:a, "Alpha"}, {:b, "Beta"}]) do
              {:select, id} -> %{model | tab: id}
              :noop -> model
            end

          _ ->
            model
        end
      end

  Bindings:

    * `Left` / `Right` — cycle tabs (with wrap)
    * `Home` / `End` — first / last
    * anything else — `:noop`
  """

  @type id :: any()
  @type item :: {id(), String.t()}
  @type event :: {:select, id()} | :noop

  @doc """
  Map a `{:key, key, mods}` event to a selection change.
  """
  @spec apply_key({:key, any(), [atom()]}, id(), [item()]) :: event()
  def apply_key({:key, :left, _}, active, items), do: cycle(items, active, -1)
  def apply_key({:key, :right, _}, active, items), do: cycle(items, active, +1)
  def apply_key({:key, :home, _}, _active, [{id, _} | _]), do: {:select, id}
  def apply_key({:key, :end, _}, _active, items), do: {:select, items |> List.last() |> elem(0)}
  def apply_key(_, _, _), do: :noop

  defp cycle([], _active, _delta), do: :noop

  defp cycle(items, active, delta) do
    ids = Enum.map(items, fn {id, _} -> id end)

    case Enum.find_index(ids, &(&1 == active)) do
      nil ->
        # Active id isn't in the list — pick first (forward) or last (backward).
        if delta > 0, do: {:select, List.first(ids)}, else: {:select, List.last(ids)}

      idx ->
        n = length(ids)
        new_idx = rem(idx + delta + n, n)

        case Enum.at(ids, new_idx) do
          ^active -> :noop
          new_id -> {:select, new_id}
        end
    end
  end
end
