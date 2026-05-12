defmodule Harlock.Elements do
  @moduledoc false
  # View-tree constructors. Imported into apps via `use Harlock.App`.
  #
  # v0.1 primitives: text, vbox, hbox, spacer, list, table, overlay, box.
  # text_input, viewport, progress, spinner arrive in subsequent steps.

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
    over = Keyword.fetch!(opts, :over)

    %Element{
      type: :overlay,
      opts: [
        anchor: Keyword.get(opts, :anchor, :center),
        width: Keyword.get(opts, :width),
        height: Keyword.get(opts, :height),
        focus_trap: Keyword.get(opts, :focus_trap, false)
      ],
      children: [child, over]
    }
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

  defp default_constraints(children), do: Enum.map(children, fn _ -> {:fill, 1} end)
end
