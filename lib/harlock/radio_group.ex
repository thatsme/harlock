defmodule Harlock.RadioGroup do
  @moduledoc """
  Key-event helper for the `Harlock.Elements.radio_group/1` widget.

  A radio group shows every option at once and has exactly one chosen. Unlike a
  `menu`, there is no highlight separate from the choice: the arrows move the
  choice itself, as radio buttons do everywhere, so there is nothing to confirm
  with Enter. Unlike a `select`, nothing opens.

  Bindings:

    * `Up` / `Left` — the previous option (wrapping)
    * `Down` / `Right` — the next option (wrapping)
    * `Home` / `End` — the first / last option
    * anything else — `:noop`, including `Enter` and `Space`

  Both arrow pairs work whichever way the group is laid out, so a group can
  change direction without its keys changing. With no option chosen yet, the
  forward keys choose the first and the backward keys the last.

  ## Auto-routing

  With a `:focusable` id the runtime calls `apply_key/3` for you (and, with
  `mouse: true`, a click on an option does the same) and delivers
  `{:harlock_select, focus_id, value}` — the message `tabs` and `menu` already
  send — for `update/2` to write back:

      radio_group(focusable: :size, items: [s: "Small", m: "Medium", l: "Large"], value: m.size)

      def update({:harlock_select, :size, size}, m), do: %{m | size: size}
  """

  @type id :: any()
  @type item :: {id(), String.t()}
  @type event :: {:select, id()} | :noop

  @doc """
  Map a `{:key, key, mods}` event to the option it chooses.

  Returns `:noop` when the choice would not change, so the key falls through to
  `update/2` rather than arriving as a message choosing what is already chosen.
  """
  @spec apply_key({:key, any(), [atom()]}, id(), [item()]) :: event()
  def apply_key(event, value, items)

  def apply_key(_event, _value, []), do: :noop

  def apply_key({:key, key, _}, value, items) when key in [:up, :left], do: step(items, value, -1)

  def apply_key({:key, key, _}, value, items) when key in [:down, :right],
    do: step(items, value, 1)

  def apply_key({:key, :home, _}, value, [{id, _} | _]), do: choose(id, value)

  def apply_key({:key, :end, _}, value, items),
    do: items |> List.last() |> elem(0) |> choose(value)

  def apply_key(_event, _value, _items), do: :noop

  defp step(items, value, delta) do
    ids = Enum.map(items, &elem(&1, 0))

    case Enum.find_index(ids, &(&1 == value)) do
      nil -> choose(if(delta > 0, do: List.first(ids), else: List.last(ids)), value)
      index -> ids |> Enum.at(rem(index + delta + length(ids), length(ids))) |> choose(value)
    end
  end

  defp choose(value, value), do: :noop
  defp choose(id, _value), do: {:select, id}
end
