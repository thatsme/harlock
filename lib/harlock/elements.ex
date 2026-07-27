defmodule Harlock.Elements do
  @moduledoc """
  View-tree constructors. Auto-imported into apps via `use Harlock.App`,
  so most apps use `text(...)`, `vbox(...)`, `box(...)` etc. directly
  without qualification.

  An element is a plain struct (`Harlock.Element`); building a view is
  just calling these functions to assemble a tree. The renderer walks
  the tree once per dirty frame and produces a `Frame` ready for the
  diff renderer.

  ## Primitives

    * `text/2` — single-line text content
    * `text_input/1` — single-line editable input (paired with
      `Harlock.TextBuffer`)
    * `vbox/1` / `hbox/1` — vertical / horizontal stacks with layout
      constraints (`:length`, `:percentage`, `:fill`)
    * `box/1` — single-child container with border + title + padding
    * `spacer/0` — empty element that occupies a layout slot
    * `overlay/1` — render a foreground element on top of a background
      with optional `focus_trap`
    * `table/1` / `list/2` — row-based primitives with selection and
      focus highlighting
    * `column/1` — column spec for `table/1`

  All elements that accept focus take a `:focusable` opt — the runtime
  walks the tree to collect focusable ids for Tab traversal.
  """

  alias Harlock.{Element, Element.Column}

  @doc """
  A text element. `content` is rendered as a single line; callers split
  multi-line content themselves.

  Options:
    * `:style` — `%Harlock.Render.Style{}` or keyword list of style attrs.
  """
  @spec text(String.t(), keyword()) :: Element.t()
  def text(content, opts \\ []) when is_binary(content) do
    %Element{type: :text, opts: [content: content] ++ opts, children: []}
  end

  @doc """
  Vertical stack. Children share the box's width; height is split according
  to `:constraints`.

  Options:
    * `:constraints` — list of layout constraints, one per child. Defaults
      to `[fill: 1]` for each child if not provided.
    * `:children` — list of child elements.
  """
  @spec vbox(keyword()) :: Element.t()
  def vbox(opts \\ []) when is_list(opts) do
    children = Keyword.get(opts, :children, [])
    constraints = Keyword.get(opts, :constraints, default_constraints(children))
    opts = opts |> Keyword.delete(:children) |> Keyword.put(:constraints, constraints)
    %Element{type: :vbox, opts: opts, children: children}
  end

  @doc """
  Horizontal stack. Children share the box's height; width is split.

  Options as `vbox/1`.
  """
  @spec hbox(keyword()) :: Element.t()
  def hbox(opts \\ []) when is_list(opts) do
    children = Keyword.get(opts, :children, [])
    constraints = Keyword.get(opts, :constraints, default_constraints(children))
    opts = opts |> Keyword.delete(:children) |> Keyword.put(:constraints, constraints)
    %Element{type: :hbox, opts: opts, children: children}
  end

  @doc "Empty cell that occupies a layout slot. Useful with constraints."
  @spec spacer() :: Element.t()
  def spacer, do: %Element{type: :spacer, opts: [], children: []}

  @doc """
  A single-child container with a border and optional inner padding.

  Required options:
    * `:child` — the element drawn inside the box

  Optional:
    * `:title` — string overlaid on the top border (truncated to fit)
    * `:title_align` — `:left` (default) | `:center` | `:right`
    * `:border` — `:single` (default) | `:double` | `:rounded` | `:thick` | `:none`
    * `:border_style` — `%Style{}` or keyword applied to the border + title
    * `:padding` — non-negative integer (uniform), `{v, h}`, or `{top, right, bottom, left}`
    * `:focusable`, `:focus_style` — when focused, the focus style replaces
      the border style (the child is left alone)

  For multiple children, wrap them in `vbox/1` or `hbox/1` and pass the
  result as `:child`. The box reserves one cell on each side for the border
  (unless `:border` is `:none`); when the region is smaller than that the
  border is skipped and the child takes the full region.
  """
  @spec box(keyword()) :: Element.t()
  def box(opts) when is_list(opts) do
    child = Keyword.fetch!(opts, :child)
    %Element{type: :box, opts: Keyword.delete(opts, :child), children: [child]}
  end

  @doc """
  Render `over` on top of `child` in a sub-rectangle anchored within the
  parent region.

  Required options:
    * `:child` — the background element (rendered first)
    * `:over` — the foreground element (rendered on top)

  Anchor + sizing:
    * `:anchor` — `:center` (default), `:top_left`, `:top_right`,
      `:bottom_left`, `:bottom_right`, or `{row, col}` for absolute placement
    * `:width`  — width of the over region in cells (default: full parent)
    * `:height` — height of the over region in cells (default: full parent)

  Focus:
    * `:focus_trap` — when true, focus traversal wraps within the `over`
      subtree until the overlay disappears. Prior focus is stashed and
      restored automatically when the overlay closes.

  Overlays nest cleanly: just put another overlay as `:over`.
  """
  @spec overlay(keyword()) :: Element.t()
  def overlay(opts) when is_list(opts) do
    child = Keyword.fetch!(opts, :child)
    over_raw = Keyword.fetch!(opts, :over)
    focus_trap? = Keyword.get(opts, :focus_trap, false)

    # focus_trap on overlay means "trap focus inside the OVER subtree" — so we
    # set it on the over element directly. Putting it on the overlay element
    # itself would include the background `child` in the trap, which would
    # let Tab leak from a modal into the underlying widgets.
    over = if focus_trap?, do: put_focus_trap(over_raw), else: over_raw

    %Element{
      type: :overlay,
      opts: [
        anchor: Keyword.get(opts, :anchor, :center),
        width: Keyword.get(opts, :width),
        height: Keyword.get(opts, :height)
      ],
      children: [child, over]
    }
  end

  defp put_focus_trap(%Element{opts: opts} = el) do
    %{el | opts: Keyword.put(opts, :focus_trap, true)}
  end

  @doc """
  Build a column spec for use inside `table/1`.

  Options:
    * `:title`  — header label
    * `:width`  — layout constraint (default `{:fill, 1}`)
    * `:align`  — `:left` | `:right` | `:center`
    * `:render` — `fn row -> string | iodata`
  """
  @spec column(keyword()) :: Column.t()
  def column(opts \\ []), do: struct!(Column, opts)

  @doc """
  Table primitive.

  Required options:
    * `:columns`  — list of `column/1` specs
    * `:rows`     — enumerable of row data
    * `:row_id`   — fn(row) -> id. Row identity is by id, not index, so focus
      and selection survive sort/filter.

  Optional:
    * `:focused_row` — currently-focused row id
    * `:selection`   — `:none` | `{:single, id}` | `{:multi, MapSet}`
    * `:show_header` — default `true`
    * `:focusable`, `:focus_trap` — same as other elements
  """
  @spec table(keyword()) :: Element.t()
  def table(opts) when is_list(opts) do
    unless Keyword.has_key?(opts, :row_id) do
      raise ArgumentError,
            "table/1 requires :row_id (rows must be identified by id, not index)"
    end

    unless Keyword.has_key?(opts, :columns) do
      raise ArgumentError, "table/1 requires :columns"
    end

    unless Keyword.has_key?(opts, :rows) do
      raise ArgumentError, "table/1 requires :rows"
    end

    %Element{type: :table, opts: opts, children: []}
  end

  @doc """
  Single-column table with chrome hidden. `:row_id` defaults to `& &1`
  because lists are usually homogeneous; pass an explicit `:row_id` if
  yours aren't.

  Options:
    * `:render`  — `fn item -> string`; defaults to `to_string/1`
    * any option accepted by `table/1`
  """
  @spec list(Enumerable.t(), keyword()) :: Element.t()
  def list(items, opts \\ []) do
    base = [
      columns: [column(width: {:fill, 1}, render: Keyword.get(opts, :render))],
      rows: items,
      row_id: Keyword.get(opts, :row_id, & &1),
      show_header: false
    ]

    table(Keyword.merge(base, Keyword.drop(opts, [:render])))
  end

  @doc """
  Scrollable container.

  Required options:
    * `:child`          — the element to scroll
    * `:offset`         — top-row offset into the child (0-indexed, app-owned)
    * `:content_height` — total rows the child occupies

  Optional:
    * `:scrollbar` — render a single-column cosmetic scrollbar on the
      right edge (default `false`). The scrollbar consumes one column
      from the child's available width.
    * `:scrollbar_style` — `%Style{}` for the scrollbar track + thumb

  The viewport renders the child into a temporary frame of
  `width × content_height`, then blits rows `offset..offset+visible_height`
  into the real region. The app owns the scroll offset; pair with
  `Harlock.Viewport.apply_key/4` in `update/2` to translate scroll-key
  events into new offsets.

  Vertical-only for now. The child is given full width (minus scrollbar
  column if enabled) so horizontal layout proceeds normally.
  """
  @spec viewport(keyword()) :: Element.t()
  def viewport(opts) when is_list(opts) do
    child = Keyword.fetch!(opts, :child)

    unless Keyword.has_key?(opts, :offset) do
      raise ArgumentError, "viewport/1 requires :offset"
    end

    unless Keyword.has_key?(opts, :content_height) do
      raise ArgumentError, "viewport/1 requires :content_height"
    end

    %Element{
      type: :viewport,
      opts: Keyword.delete(opts, :child),
      children: [child]
    }
  end

  @doc """
  Single-line text input.

  Required options:
    * `:value`     — the current string contents (caller-owned)
    * `:cursor`    — grapheme index of the cursor (0..length)
    * `:focusable` — id for focus traversal

  Optional:
    * `:placeholder`      — shown when value is empty and the input isn't focused
    * `:max_length`       — soft hint; the element doesn't enforce it, but
      `Harlock.TextBuffer.apply_key/3` respects it if you wire it in your app
    * `:style`            — `%Style{}` for the value text
    * `:placeholder_style`— `%Style{}` for the placeholder
    * `:password`         — when true, render each grapheme as `•`

  The element is a dumb renderer. The app's `update/2` owns the value and
  cursor; call `Harlock.TextBuffer.apply_key/3` to react to key events
  when this input is focused. When focused, the renderer positions the
  terminal cursor at the visual column matching `:cursor`.
  """
  @spec text_input(keyword()) :: Element.t()
  def text_input(opts) when is_list(opts) do
    unless Keyword.has_key?(opts, :value) do
      raise ArgumentError, "text_input/1 requires :value"
    end

    unless Keyword.has_key?(opts, :cursor) do
      raise ArgumentError, "text_input/1 requires :cursor"
    end

    unless Keyword.has_key?(opts, :focusable) do
      raise ArgumentError, "text_input/1 requires :focusable"
    end

    %Element{type: :text_input, opts: opts, children: []}
  end

  @doc """
  Multi-line text area.

  Required options:
    * `:value`     — the current contents, lines separated by `\\n` (caller-owned)
    * `:cursor`    — flat grapheme index of the cursor (0..length)
    * `:focusable` — id for focus traversal

  Optional:
    * `:wrap`             — when true, wrap long lines at the rendered width
      (default `false`, which clips instead)
    * `:scroll`           — index of the first visible display row (default `0`)
    * `:placeholder`      — shown when value is empty and the area isn't focused
    * `:style`            — `%Style{}` for the text
    * `:placeholder_style`— `%Style{}` for the placeholder

  Like `text_input/1` this is a dumb renderer: the app's `update/2` owns the
  value and cursor, and `Harlock.TextArea.apply_key/3` maps key events onto
  them. When the area is focused the runtime routes keys automatically and
  delivers `{:harlock_edit, focus_id, {value, cursor}}` — the same message a
  `text_input` produces, because both use the same `(value, cursor)` shape.

  With `wrap: true` long lines break across display rows at word boundaries,
  and `↑` / `↓` / Home / End follow those rows rather than logical lines.
  Without it, long lines are clipped.

  `:scroll` is app-owned in the same way `viewport/1` owns `:offset`, and
  counts display rows; the renderer adjusts it by the minimum needed to keep
  the cursor on screen, so passing nothing still draws a usable cursor. See
  `Harlock.TextArea.scroll_to_reveal/5` for threading it back onto the model.
  """
  @spec textarea(keyword()) :: Element.t()
  def textarea(opts) when is_list(opts) do
    for required <- [:value, :cursor, :focusable] do
      unless Keyword.has_key?(opts, required) do
        raise ArgumentError, "textarea/1 requires #{inspect(required)}"
      end
    end

    %Element{type: :textarea, opts: opts, children: []}
  end

  @doc """
  Single-line horizontal progress bar.

  Required options:
    * `:value` — current value (non-negative)
    * `:max`   — denominator (positive)

  Optional:
    * `:width`      — explicit bar width in cells (default: full region width)
    * `:style`      — `%Style{}` for the unfilled portion
    * `:fill_style` — `%Style{}` for the filled portion

  `value` is clamped to `[0, max]`. The bar fills
  `round(value / max * width)` cells with `█` in `fill_style` and the
  rest with space in `style`.
  """
  @spec progress(keyword()) :: Element.t()
  def progress(opts) when is_list(opts) do
    unless Keyword.has_key?(opts, :value), do: raise(ArgumentError, "progress/1 requires :value")
    unless Keyword.has_key?(opts, :max), do: raise(ArgumentError, "progress/1 requires :max")
    %Element{type: :progress, opts: opts, children: []}
  end

  @doc """
  Single-cell animated spinner.

  Required options:
    * `:tick` — integer; the current animation frame counter (caller-owned
      in the app's model). Pair with a subscription that increments
      this on a timer.

  Optional:
    * `:frames` — list of grapheme strings to cycle through
      (default: braille spinner `["⠋", "⠙", …]`)
    * `:style` — `%Style{}` applied to the rendered frame

  Renders `Enum.at(frames, rem(tick, length(frames)))`. The widget
  doesn't subscribe to anything itself — wire `Harlock.Sub.interval/2`
  in your app's `subs/1` and increment `tick` in `update/2`.
  """
  @spec spinner(keyword()) :: Element.t()
  def spinner(opts) when is_list(opts) do
    unless Keyword.has_key?(opts, :tick), do: raise(ArgumentError, "spinner/1 requires :tick")
    %Element{type: :spinner, opts: opts, children: []}
  end

  @doc """
  Single-line bar with left- and right-aligned text. Useful as the
  pinned-bottom row of a screen.

  Options:
    * `:left`  — string (default `""`)
    * `:right` — string (default `""`)
    * `:style` — `%Style{}` (default `%Style{reverse: true}`)

  If `left` and `right` together exceed the region width, `right` is
  truncated first.
  """
  @spec statusbar(keyword()) :: Element.t()
  def statusbar(opts \\ []) when is_list(opts) do
    %Element{type: :statusbar, opts: opts, children: []}
  end

  @doc """
  Single-line bar showing key bindings as `[k] label  [k] label`.

  Required:
    * `:bindings` — list of `{key, label}` tuples. `key` may be a char
      like `?q` or any atom (`:tab`, `:enter`); it's rendered via
      `to_string/1`.

  Optional:
    * `:style` — `%Style{}` (default `%Style{reverse: true}`)
    * `:separator` — string between bindings (default `"  "`)
    * `:right` — extra right-aligned text (e.g. clock, status)
  """
  @spec keybar(keyword()) :: Element.t()
  def keybar(opts) when is_list(opts) do
    unless Keyword.has_key?(opts, :bindings) do
      raise ArgumentError, "keybar/1 requires :bindings"
    end

    %Element{type: :keybar, opts: opts, children: []}
  end

  @doc """
  Single-line horizontal tab bar.

  Required:
    * `:items`  — list of `{id, label}` tuples
    * `:active` — id of the currently active tab

  Optional:
    * `:focusable` — focus id; when focused, Left/Right cycle tabs (use
      `Harlock.Tabs.apply_key/3` in `update/2`)
    * `:style`         — `%Style{}` for inactive tabs (default `Theme.get(:header)`)
    * `:active_style`  — `%Style{}` for the active tab (default `Theme.get(:focus)`)
    * `:separator`     — string between tabs (default `" │ "`)

  Renders only the tab bar — the body for the active tab is rendered
  separately by the app. Typical pattern:

      vbox(
        constraints: [length: 1, fill: 1],
        children: [
          tabs(items: [{:a, "Alpha"}, {:b, "Beta"}], active: m.tab, focusable: :tabs),
          case m.tab do
            :a -> alpha_body(m)
            :b -> beta_body(m)
          end
        ]
      )
  """
  @spec tabs(keyword()) :: Element.t()
  def tabs(opts) when is_list(opts) do
    unless Keyword.has_key?(opts, :items), do: raise(ArgumentError, "tabs/1 requires :items")
    unless Keyword.has_key?(opts, :active), do: raise(ArgumentError, "tabs/1 requires :active")
    %Element{type: :tabs, opts: opts, children: []}
  end

  @doc """
  Vertical menu: a list of labels with one highlighted.

  Required options:
    * `:items`  — list of `{id, label}` tuples
    * `:active` — id of the currently highlighted item

  Optional:
    * `:focusable`    — focus id; when focused the runtime routes `Up` / `Down` /
      `Home` / `End` as `{:harlock_select, focus_id, id}` and `Enter` as
      `{:harlock_submit, focus_id}`
    * `:style`        — `%Style{}` for unhighlighted items (default
      `Theme.get(:primary)`)
    * `:active_style` — `%Style{}` for the highlighted item (default
      `Theme.get(:focus)` when focused, `Theme.get(:selection)` otherwise)
    * `:align`        — `:left` (default) | `:right` | `:center`

  One row per item, top-aligned in the region. Longer menus clip rather than
  scroll — wrap in a `viewport/1` when the list can outgrow its space.

      menu(
        items: [{:save, "Save"}, {:reload, "Reload"}, {:quit, "Quit"}],
        active: m.action,
        focusable: :actions
      )

  Moving the highlight and committing it are separate events, so an app can
  preview on movement and act on Enter. See `Harlock.Menu` for the bindings and
  for using `apply_key/3` directly.
  """
  @spec menu(keyword()) :: Element.t()
  def menu(opts) when is_list(opts) do
    for required <- [:items, :active] do
      unless Keyword.has_key?(opts, required) do
        raise ArgumentError, "menu/1 requires #{inspect(required)}"
      end
    end

    %Element{type: :menu, opts: opts, children: []}
  end

  defp default_constraints(children), do: Enum.map(children, fn _ -> {:fill, 1} end)
end
