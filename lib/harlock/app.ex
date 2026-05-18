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
  directly. Tab / Shift-Tab are intercepted by the runtime for focus
  traversal and do **not** reach `update/2`.

  Raw input:

    * `{:key, key, [modifier()]}` — terminal key events.
      Examples: `{:key, :down, []}`, `{:key, {:char, ?q}, []}`,
      `{:key, :tab, [:shift]}`. `key` is an atom for named keys
      (`:up`, `:enter`, `:escape`, …), `{:char, codepoint}` for
      printables, `{:f, n}` for function keys.

  Focus-aware widget routing (R2, v0.4). When a focusable widget
  (`viewport`, `tabs`, `text_input`) carries a `:focusable` id and is
  focused, the runtime translates relevant keys into widget-shaped
  messages **before** calling `update/2`. The raw `{:key, …}` is
  swallowed — apps see the routed message *or* the raw key, never both.
  Opt out per-element with `handle_keys: false`. The four messages:

    * `{:harlock_scroll, focus_id, new_offset}` — focused `viewport`
      handled a scroll key (`:up`/`:down`/`:page_up`/`:page_down`/
      `:home`/`:end`). The app's clause typically just writes the
      offset back to the model:

          def update({:harlock_scroll, :log, n}, m),
            do: %{m | log_offset: n}

    * `{:harlock_select, focus_id, new_id}` — focused `tabs` widget
      moved selection (`:left`/`:right`/`:home`/`:end`):

          def update({:harlock_select, :nav, id}, m), do: %{m | tab: id}

    * `{:harlock_edit, focus_id, {new_value, new_cursor}}` — focused
      `text_input` accepted a printable character, arrow, backspace, or
      delete:

          def update({:harlock_edit, :search, {v, c}}, m),
            do: %{m | search: v, search_cursor: c}

    * `{:harlock_submit, focus_id}` — focused `text_input` saw Enter:

          def update({:harlock_submit, :search}, m), do: run_search(m)

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
