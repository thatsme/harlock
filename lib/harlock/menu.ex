defmodule Harlock.Menu do
  @moduledoc """
  Key-event helper for the `Harlock.Elements.menu/1` widget.

  A menu is a vertical list of labels with one highlighted item. The widget is
  a dumb renderer — the app holds the highlighted id in its model, exactly as
  `Harlock.Tabs` holds the active tab.

  Bindings:

    * `Up` / `Down` — move the highlight (wrapping at both ends)
    * `Home` / `End` — first / last item
    * `Enter` — commit the highlighted item
    * anything else — `:noop`

  ## Two events, not one

  Moving the highlight and choosing an item are different things, so
  `apply_key/3` distinguishes them: arrows return `{:select, id}` and Enter
  returns `:submit`. An app that only cares about the final choice ignores the
  first and acts on the second; one that previews as you move — a file picker
  showing contents, say — acts on both.

  ## Auto-routing

  When a `menu` element carries a `:focusable` id the runtime calls
  `apply_key/3` for you and delivers `{:harlock_select, focus_id, id}` as the
  highlight moves and `{:harlock_submit, focus_id}` on Enter:

      menu(focusable: :actions, items: [{:save, "Save"}, {:quit, "Quit"}],
           active: m.action)

      def update({:harlock_select, :actions, id}, m), do: %{m | action: id}
      def update({:harlock_submit, :actions}, m), do: run(m.action, m)

  Both tuples already exist — `tabs` produces the first and `text_input` the
  second — so a menu adds no new message shapes to learn. Calling
  `apply_key/3` directly from `update/2` stays supported for menus without a
  `:focusable` id, or with `handle_keys: false`.

  A menu longer than its region clips rather than scrolling, the same as
  `list/2`. Wrap it in a `viewport/1` when it can outgrow the space.
  """

  @type id :: any()
  @type item :: {id(), String.t()}
  @type event :: {:select, id()} | :submit | :noop

  @doc """
  Map a `{:key, key, mods}` event to a highlight change or a commit.

  Returns `:noop` when the highlight would not move, so an unchanged key falls
  through to the app's `update/2` instead of arriving as a no-op message.
  """
  @spec apply_key({:key, any(), [atom()]}, id(), [item()]) :: event()
  def apply_key({:key, :up, _}, active, items), do: step(items, active, -1)
  def apply_key({:key, :down, _}, active, items), do: step(items, active, +1)
  def apply_key({:key, :home, _}, active, items), do: jump(items, active, :first)
  def apply_key({:key, :end, _}, active, items), do: jump(items, active, :last)
  def apply_key({:key, :enter, _}, _active, [_ | _]), do: :submit
  def apply_key(_event, _active, _items), do: :noop

  defp step([], _active, _delta), do: :noop

  defp step(items, active, delta) do
    ids = ids(items)

    case Enum.find_index(ids, &(&1 == active)) do
      # Highlight isn't in the list — enter from the near end, so Down lands on
      # the first item and Up on the last.
      nil ->
        if delta > 0, do: {:select, List.first(ids)}, else: {:select, List.last(ids)}

      index ->
        count = length(ids)
        selected = Enum.at(ids, rem(index + delta + count, count))
        if selected == active, do: :noop, else: {:select, selected}
    end
  end

  defp jump([], _active, _where), do: :noop

  defp jump(items, active, where) do
    ids = ids(items)
    target = if where == :first, do: List.first(ids), else: List.last(ids)
    if target == active, do: :noop, else: {:select, target}
  end

  defp ids(items), do: Enum.map(items, fn {id, _label} -> id end)
end
