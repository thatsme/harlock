defmodule Harlock.Table do
  @moduledoc """
  Key-event helpers for the `Harlock.Elements.table/1` widget.

  A table has two movable things, and which one the arrows should move depends on
  how its rows were supplied:

    * **enumerable rows** — the row set is known, the visible window auto-centres
      on `:focused_row`, and moving the *focus* is what a user means. Use
      `select_key/3`, which yields `{:select, row_id}`.
    * **a window function** — there is no row set to walk and no index to centre
      on, so `:offset` is what moves. Use `scroll_key/4`, which yields
      `{:scroll, offset}`.

  The runtime picks between them automatically for a focused `table`, delivering
  `{:harlock_select, focus_id, row_id}` or `{:harlock_scroll, focus_id, offset}`
  respectively — both messages that already existed.

  Neither wraps. A table is read top-down and is often long, so jumping from the
  last row to the first reads as a glitch. `menu` wraps because its lists are
  short and cyclic movement is the convention there; this is a deliberate
  difference, not an inconsistency.
  """

  @type row_id :: any()

  @doc """
  Move `:focused_row` through a known list of row ids.

  Returns `:noop` when the focus would not move, so the key falls through to
  `update/2` instead of arriving as a message selecting what is already selected.
  """
  @spec select_key({:key, any(), [atom()]}, [row_id()], row_id()) ::
          {:select, row_id()} | :noop
  def select_key(event, ids, focused)

  def select_key(_event, [], _focused), do: :noop

  def select_key({:key, key, _mods}, ids, focused) when key in [:up, :down] do
    delta = if key == :down, do: +1, else: -1

    case Enum.find_index(ids, &(&1 == focused)) do
      # Focus is not in the list — enter from the near end rather than doing
      # nothing, which is what happens after a filter drops the focused row.
      nil -> select(if(delta > 0, do: List.first(ids), else: List.last(ids)), focused)
      index -> step(ids, index + delta)
    end
  end

  def select_key({:key, :home, _}, ids, focused), do: select(List.first(ids), focused)
  def select_key({:key, :end, _}, ids, focused), do: select(List.last(ids), focused)
  def select_key(_event, _ids, _focused), do: :noop

  defp step(ids, target) when target >= 0 do
    case Enum.at(ids, target) do
      nil -> :noop
      id -> {:select, id}
    end
  end

  defp step(_ids, _target), do: :noop

  defp select(id, focused) when id == focused, do: :noop
  defp select(nil, _focused), do: :noop
  defp select(id, _focused), do: {:select, id}

  @doc """
  Move `:offset` for a window-function table.

  `body_h` is the number of rows the body can draw, and `at_end?` says whether
  the last fetch returned fewer rows than it was asked for.

  That flag is doing real work. A window function is never asked how many rows
  exist — with keyset pagination the total may be genuinely unknown — so there is
  no maximum offset to clamp against. Without it, `:down` at the bottom would
  keep incrementing forever and scroll into empty space. A short fetch is the
  only available end-of-data signal, so the renderer reports it and this refuses
  to advance past it.

  `:end` is `:noop` for the same reason: jumping to the last row requires knowing
  where it is.
  """
  @spec scroll_key({:key, any(), [atom()]}, non_neg_integer(), pos_integer(), boolean()) ::
          {:scroll, non_neg_integer()} | :noop
  def scroll_key(event, offset, body_h, at_end?)

  def scroll_key({:key, key, _mods}, offset, body_h, at_end?) do
    page = max(1, body_h - 1)

    proposed =
      case key do
        :up -> offset - 1
        :down -> offset + 1
        :page_up -> offset - page
        :page_down -> offset + page
        :home -> 0
        _other -> offset
      end

    forward? = proposed > offset
    new_offset = max(proposed, 0)

    cond do
      forward? and at_end? -> :noop
      new_offset == offset -> :noop
      true -> {:scroll, new_offset}
    end
  end
end
