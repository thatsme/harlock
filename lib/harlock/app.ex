defmodule Harlock.App do
  @moduledoc """
  Behaviour for Harlock applications.

  An app defines three callbacks:

    * `init/1` — returns the initial model from an arbitrary init argument.
    * `update/2` — given an event and the current model, returns the next
      model, optionally paired with a `Cmd`. Return `:quit` to exit the app.
    * `view/1` — given the current model, returns an element tree.

  The simplest app:

      defmodule Counter do
        use Harlock.App

        def init(_), do: %{n: 0}

        def update({:key, {:char, ?+}, []}, m), do: %{m | n: m.n + 1}
        def update({:key, {:char, ?q}, []}, _), do: :quit
        def update(_event, m), do: m

        def view(m) do
          vbox(constraints: [length: 1, fill: 1], children: [
            text("Count: \#{m.n}"),
            text("(+ to inc, q to quit)")
          ])
        end
      end

  ## Event vocabulary

  `update/2` receives messages from several sources. The runtime
  guarantees the following tuple shapes; apps pattern-match on these
  directly.

  **Tab / Shift-Tab are consumed by the runtime for focus traversal
  whenever the current tree contains at least one focusable element**
  and do **not** reach `update/2` in that case. (When the tree has no
  focusables to cycle, the keys fall through as raw `{:key, :tab, …}`
  events.) Apps that previously dispatched on `{:key, :tab, []}` for
  sub-navigation — for example, cycling a custom highlight — should
  bind that gesture to a non-Tab key the moment a focusable widget
  enters the tree, or the binding will be silently shadowed.

  Raw input:

    * `{:key, key, [modifier()]}` — terminal key events.
      Examples: `{:key, :down, []}`, `{:key, {:char, ?q}, []}`,
      `{:key, :tab, [:shift]}`. `key` is an atom for named keys
      (`:up`, `:enter`, `:escape`, …), `{:char, codepoint}` for
      printables, `{:f, n}` for function keys.

  Focus-aware widget routing (R2, v0.4). When a focusable widget
  (`viewport`, `tabs`, `text_input`, `textarea`, `menu`, `select`,
  `tree`, `table`) carries a `:focusable` id and is focused, the runtime
  translates relevant keys into widget-shaped messages **before**
  calling `update/2`. The raw `{:key, …}` is swallowed — apps see the
  routed message *or* the raw key, never both. Opt out per-element with
  `handle_keys: false`. The five messages:

    * `{:harlock_scroll, focus_id, new_offset}` — focused `viewport`
      handled a scroll key (`:up`/`:down`/`:page_up`/`:page_down`/
      `:home`/`:end`), or a focused `table` backed by a window function
      moved its `:offset`. The app's clause typically just writes the
      offset back to the model:

          def update({:harlock_scroll, :log, n}, m),
            do: %{m | log_offset: n}

    * `{:harlock_select, focus_id, new_id}` — a focused `tabs`, `menu`,
      `select`, `tree`, or list-backed `table` moved its selection,
      highlight, or focused row:

          def update({:harlock_select, :nav, id}, m), do: %{m | tab: id}

    * `{:harlock_toggle, focus_id, node_id}` — a focused `tree` expanded
      or collapsed a node. Distinct from `:harlock_select` because
      expanding is not selecting, and because a node whose children are
      not loaded yet turns this into a side effect:

          def update({:harlock_toggle, :files, id}, m) do
            {%{m | nodes: mark_loading(m.nodes, id)}, Cmd.from(fn -> fetch(id) end)}
          end

    * `{:harlock_edit, focus_id, {new_value, new_cursor}}` — focused
      `text_input` accepted a printable character, arrow, backspace, or
      delete:

          def update({:harlock_edit, :search, {v, c}}, m),
            do: %{m | search: v, search_cursor: c}

    * `{:harlock_submit, focus_id}` — the action key was pressed on a
      focused `text_input`, `menu`, `select`, or `tree` leaf:

          def update({:harlock_submit, :search}, m), do: run_search(m)

      For a `select` this means "open the list" or "commit the
      highlight" depending on state the app already holds, which is why
      there is no separate open/close message.

  No-op key events (e.g. `:up` on a viewport already at offset 0, or a
  modifier-only press in a text input) fall through to `update/2` as
  raw `{:key, …}` events so apps can still react if they want.

  Cmd results and Sub-produced messages have whatever shape the app
  defined via `Cmd.map/2` and friends — those are not part of the
  runtime's vocabulary.
  """

  alias Harlock.{Cmd, Element}

  @type model :: any()
  @type msg :: any()

  @callback init(any()) :: model() | {model(), Cmd.t()}
  @callback update(msg(), model()) :: model() | {model(), Cmd.t()} | :quit | {:quit, Cmd.t()}
  @callback view(model()) :: Element.t()
  @callback subs(model()) :: [Harlock.Sub.t()]

  @optional_callbacks subs: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Harlock.App
      import Harlock.Elements
      alias Harlock.{Cmd, Sub}
      alias Harlock.Render.Style
    end
  end
end
