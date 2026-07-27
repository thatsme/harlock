defmodule Harlock.Select do
  @moduledoc """
  Key-event helper for the `Harlock.Elements.select/1` dropdown.

  The app owns both the chosen value and whether the list is open, the same way
  it owns a `text_input`'s value. The widget renders what the model says and
  maps keys onto it.

  Bindings, closed:

    * `Enter` / `Space` / `Down` — `:submit`, meaning "open me"
    * anything else — `:noop`

  Bindings, open:

    * `Up` / `Down` — move the highlight (wrapping), `{:select, id}`
    * `Home` / `End` — first / last
    * `Enter` / `Space` — `:submit`, meaning "commit the highlight and close"
    * anything else — `:noop`, including `Escape`

  ## Why `:submit` means two things

  It means one thing — "the user pressed the action key" — and the app already
  knows whether its own dropdown is open, so it needs no help distinguishing
  them:

      def update({:harlock_submit, :country}, %{open: false} = m),
        do: %{m | open: true}

      def update({:harlock_submit, :country}, %{open: true} = m),
        do: %{m | open: false, value: m.highlight}

  The alternative was a routed `{:harlock_open, …}` / `{:harlock_close, …}`
  pair, which would add message shapes to a contract a 1.0 freeze locks, in
  order to tell the app something it can already see in its own model.

  ## Escape

  `Escape` deliberately stays `:noop` and falls through to `update/2` as a raw
  key. Cancelling is not always local — some apps close the dropdown, others
  treat `Escape` globally — and a widget that swallowed it would take that
  choice away. Close on it explicitly:

      def update({:key, :escape, []}, %{open: true} = m), do: %{m | open: false}

  Order that clause before any global `Escape` handler, or an open dropdown
  will quit the app.

  ## Auto-routing

  With a `:focusable` id the runtime calls `apply_key/4` for you and delivers
  `{:harlock_select, focus_id, id}` as the highlight moves plus
  `{:harlock_submit, focus_id}` on the action key — the same two tuples `menu`
  uses, so a dropdown adds nothing new to learn.
  """

  @type id :: any()
  @type item :: {id(), String.t()}
  @type event :: {:select, id()} | :submit | :noop

  @doc """
  Map a `{:key, key, mods}` event onto a dropdown in the given open state.

  `highlight` is the currently highlighted id — the chosen value while closed,
  and wherever the arrows have moved to while open.
  """
  @spec apply_key({:key, any(), [atom()]}, id(), [item()], boolean()) :: event()
  def apply_key(event, highlight, items, open?)

  # Closed: the action keys open the list, and Down opens it too — a
  # convention worth keeping, since reaching for the list is why you are here.
  def apply_key({:key, :enter, _}, _highlight, [_ | _], false), do: :submit
  def apply_key({:key, {:char, ?\s}, _}, _highlight, [_ | _], false), do: :submit
  def apply_key({:key, :down, _}, _highlight, [_ | _], false), do: :submit
  def apply_key(_event, _highlight, _items, false), do: :noop

  # Open: navigation delegates to Menu so both widgets move a highlight the
  # same way, including the wrap and the noop-when-unmoved behaviour.
  def apply_key({:key, :enter, _}, _highlight, [_ | _], true), do: :submit
  def apply_key({:key, {:char, ?\s}, _}, _highlight, [_ | _], true), do: :submit

  def apply_key({:key, key, mods}, highlight, items, true)
      when key in [:up, :down, :home, :end] do
    Harlock.Menu.apply_key({:key, key, mods}, highlight, items)
  end

  def apply_key(_event, _highlight, _items, true), do: :noop
end
