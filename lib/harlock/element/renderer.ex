defmodule Harlock.Element.Renderer do
  @moduledoc false
  # Walks an element tree, applying the layout solver to vbox/hbox, and lays
  # cells down into a Frame. Pure function — no I/O.

  alias Harlock.Element
  alias Harlock.Element.Column
  alias Harlock.Element.Floats
  alias Harlock.Element.WidgetMetrics
  alias Harlock.Layout
  alias Harlock.Layout.Rect
  alias Harlock.Render.Buffer
  alias Harlock.Render.Frame
  alias Harlock.Render.Style
  alias Harlock.Render.StyleTable
  alias Harlock.TextArea
  alias Harlock.TextBuffer
  alias Harlock.Theme
  alias Harlock.Width

  @border_chars %{
    single: {"┌", "┐", "└", "┘", "─", "│"},
    double: {"╔", "╗", "╚", "╝", "═", "║"},
    rounded: {"╭", "╮", "╰", "╯", "─", "│"},
    thick: {"┏", "┓", "┗", "┛", "━", "┃"}
  }

  # Guards the float pass against a widget that pushes a float every time it is
  # drawn. Nesting deeper than this is a bug, not a layout.
  @max_float_depth 8

  @spec render(Element.t(), non_neg_integer(), non_neg_integer(), any()) :: Frame.t()
  def render(%Element{} = root, rows, cols, focused \\ nil) do
    frame = Frame.new(rows, cols)
    region = Rect.new(0, 0, cols, rows)

    Floats.clear()
    frame = render_element(root, region, frame, focused)
    draw_floats(frame, rows, cols, focused, @max_float_depth)
  end

  # Deferred draws, in push order. Rendering a float may itself push one — a
  # submenu off a menu — so this repeats until nothing new arrives.
  defp draw_floats(frame, _rows, _cols, _focused, 0), do: frame

  defp draw_floats(frame, rows, cols, focused, depth) do
    case Floats.drain() do
      [] ->
        frame

      floats ->
        floats
        |> Enum.reduce(frame, fn %{anchor: anchor, w: w, h: h, element: el}, acc ->
          render_element(el, float_region(anchor, w, h, rows, cols), acc, focused)
        end)
        |> draw_floats(rows, cols, focused, depth - 1)
    end
  end

  # Place a panel against its anchor, flipping rather than clipping when it
  # will not fit. Opening below and to the left is the default because that is
  # where a reader looks next; the flips are what keep a control near the right
  # or bottom margin usable instead of half off-screen.
  @doc false
  @spec float_region(
          Rect.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          Rect.t()
  def float_region(anchor, w, h, rows, cols) do
    w = w |> min(cols) |> max(0)
    h = h |> min(rows) |> max(0)

    below = anchor.row + anchor.h

    row =
      cond do
        # Below the control, the common case.
        below + h <= rows -> below
        # Flipped above: the panel ends where the control begins.
        anchor.row - h >= 0 -> anchor.row - h
        # Fits neither side — bottom-align so as much as possible is readable
        # rather than letting the tail run off the screen.
        true -> max(rows - h, 0)
      end

    col = if anchor.col + w <= cols, do: anchor.col, else: max(cols - w, 0)

    Rect.new(row, col, w, h)
  end

  defp render_element(_element, %Rect{w: 0}, frame, _focused), do: frame
  defp render_element(_element, %Rect{h: 0}, frame, _focused), do: frame

  defp render_element(%Element{type: :text} = el, region, frame, focused) do
    content = Keyword.fetch!(el.opts, :content)

    style =
      el.opts
      |> Keyword.get(:style, %Style{})
      |> Style.from()
      |> maybe_focus_style(el, focused)

    text = clip(content, region.w)
    Frame.write(frame, region.row, region.col, text, style)
  end

  defp render_element(%Element{type: :text_input} = el, region, frame, focused) do
    value = Keyword.fetch!(el.opts, :value)
    cursor = Keyword.fetch!(el.opts, :cursor)
    id = Keyword.fetch!(el.opts, :focusable)
    placeholder = Keyword.get(el.opts, :placeholder, "")
    password? = Keyword.get(el.opts, :password, false)

    is_focused? = id == focused
    show_placeholder? = value == "" and not is_focused?

    {text, text_style} =
      if show_placeholder? do
        ph_style =
          el.opts
          |> Keyword.get(:placeholder_style, %Style{dim: true})
          |> Style.from()

        {placeholder, ph_style}
      else
        rendered = if password?, do: mask(value), else: value

        v_style =
          el.opts
          |> Keyword.get(:style, %Style{})
          |> Style.from()

        {rendered, v_style}
      end

    text = clip(text, region.w)
    frame = Frame.write(frame, region.row, region.col, text, text_style)

    frame =
      if is_focused? do
        frame
        |> Frame.set_focus_rect(rect_of(region))
        |> Frame.set_cursor(
          {region.row, region.col + min(TextBuffer.cursor_column(value, cursor), region.w - 1)}
        )
      else
        frame
      end

    frame
  end

  defp render_element(%Element{type: :textarea} = el, region, frame, focused) do
    value = Keyword.fetch!(el.opts, :value)
    cursor = Keyword.fetch!(el.opts, :cursor)
    id = Keyword.fetch!(el.opts, :focusable)
    scroll = Keyword.get(el.opts, :scroll, 0)

    is_focused? = id == focused
    show_placeholder? = value == "" and not is_focused?

    if show_placeholder? do
      ph_style = el.opts |> Keyword.get(:placeholder_style, %Style{dim: true}) |> Style.from()
      placeholder = Keyword.get(el.opts, :placeholder, "")
      Frame.write(frame, region.row, region.col, clip(placeholder, region.w), ph_style)
    else
      style = el.opts |> Keyword.get(:style, %Style{}) |> Style.from()
      wrap_width = if Keyword.get(el.opts, :wrap, false) and region.w > 0, do: region.w

      # The runtime needs the wrap width to route vertical motion by display
      # row rather than logical line. nil when wrapping is off, which is
      # exactly what TextArea.apply_key/5 expects.
      WidgetMetrics.record(Keyword.get(el.opts, :focusable), %{textarea_wrap_width: wrap_width})

      rows = TextArea.visual_rows(value, wrap_width)
      {cursor_row, cursor_column} = TextArea.visual_position(value, cursor, wrap_width)
      top = TextArea.scroll_to_reveal(scroll, value, cursor, region.h, wrap_width)

      frame =
        rows
        |> Enum.slice(top, region.h)
        |> Enum.with_index()
        |> Enum.reduce(frame, fn {{_start, text}, i}, f ->
          Frame.write(f, region.row + i, region.col, clip(text, region.w), style)
        end)

      if is_focused? do
        frame
        |> Frame.set_focus_rect(rect_of(region))
        |> Frame.set_cursor(
          {region.row + (cursor_row - top), region.col + min(cursor_column, region.w - 1)}
        )
      else
        frame
      end
    end
  end

  defp render_element(%Element{type: :progress} = el, region, frame, _focused) do
    value = max(0, Keyword.fetch!(el.opts, :value))
    max_val = Keyword.fetch!(el.opts, :max)
    width = Keyword.get(el.opts, :width, region.w) |> min(region.w) |> max(0)
    style = el.opts |> Keyword.get(:style, %Style{}) |> Style.from()
    fill_style = el.opts |> Keyword.get(:fill_style, %Style{fg: :cyan}) |> Style.from()

    clamped = min(value, max_val)
    filled = if max_val > 0, do: round(clamped / max_val * width), else: 0
    filled = filled |> min(width) |> max(0)
    empty = width - filled

    frame
    |> Frame.write(region.row, region.col, String.duplicate("█", filled), fill_style)
    |> Frame.write(region.row, region.col + filled, String.duplicate(" ", empty), style)
  end

  defp render_element(%Element{type: :spinner} = el, region, frame, _focused) do
    tick = Keyword.fetch!(el.opts, :tick)
    frames = Keyword.get(el.opts, :frames, ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏))
    style = el.opts |> Keyword.get(:style, %Style{}) |> Style.from()

    glyph = Enum.at(frames, rem(max(tick, 0), length(frames)))
    Frame.write(frame, region.row, region.col, glyph, style)
  end

  defp render_element(%Element{type: :statusbar} = el, region, frame, _focused) do
    left = Keyword.get(el.opts, :left, "")
    right = Keyword.get(el.opts, :right, "")
    style = el.opts |> Keyword.get(:style, %Style{reverse: true}) |> Style.from()

    render_lr_bar(frame, region, left, right, style)
  end

  defp render_element(%Element{type: :keybar} = el, region, frame, _focused) do
    bindings = Keyword.fetch!(el.opts, :bindings)
    separator = Keyword.get(el.opts, :separator, "  ")
    right = Keyword.get(el.opts, :right, "")
    style = el.opts |> Keyword.get(:style, %Style{reverse: true}) |> Style.from()

    left = bindings |> Enum.map_join(separator, &format_binding/1)
    render_lr_bar(frame, region, left, right, style)
  end

  defp render_element(%Element{type: :tabs} = el, region, frame, focused) do
    items = Keyword.fetch!(el.opts, :items)
    active = Keyword.fetch!(el.opts, :active)
    separator = Keyword.get(el.opts, :separator, " │ ")
    is_focused? = Keyword.get(el.opts, :focusable) == focused

    inactive_style = el.opts |> Keyword.get(:style, Theme.get(:header)) |> Style.from()

    active_style =
      el.opts
      |> Keyword.get(:active_style, default_tabs_active_style(is_focused?))
      |> Style.from()

    sep_style = %Style{dim: true}

    render_tabs(frame, region, items, active, separator, inactive_style, active_style, sep_style)
  end

  defp render_element(%Element{type: :menu} = el, region, frame, focused) do
    items = Keyword.fetch!(el.opts, :items)
    active = Keyword.fetch!(el.opts, :active)
    align = Keyword.get(el.opts, :align, :left)
    is_focused? = Keyword.get(el.opts, :focusable) == focused

    base = el.opts |> Keyword.get(:style, Theme.get(:primary)) |> Style.from()

    active_style =
      el.opts
      |> Keyword.get(:active_style, default_menu_active_style(is_focused?))
      |> Style.from()

    # One row per item, top-aligned; anything past the region's height clips,
    # matching list/2. A menu that can outgrow its space belongs in a viewport.
    items
    |> Enum.take(region.h)
    |> Enum.with_index()
    |> Enum.reduce(frame, fn {{id, label}, index}, acc ->
      style = if id == active, do: active_style, else: base
      render_cell(acc, region.row + index, region.col, region.w, label, align, style)
    end)
  end

  defp render_element(%Element{type: :select} = el, region, frame, focused) do
    items = Keyword.fetch!(el.opts, :items)
    value = Keyword.fetch!(el.opts, :value)
    open? = Keyword.fetch!(el.opts, :open)
    id = Keyword.get(el.opts, :focusable)
    is_focused? = not is_nil(id) and id == focused
    marker = Keyword.get(el.opts, :marker, if(open?, do: "▴", else: "▾"))

    label =
      case Enum.find(items, fn {item_id, _} -> item_id == value end) do
        {_id, text} -> text
        nil -> Keyword.get(el.opts, :placeholder, "")
      end

    style =
      el.opts
      |> Keyword.get(:style, if(is_focused?, do: Theme.get(:focus), else: %Style{}))
      |> Style.from()

    # The marker sits hard right so the control reads as a dropdown at any
    # width; the label takes what is left.
    marker_w = Width.string_width(marker)
    label_w = max(region.w - marker_w - 1, 0)

    frame =
      frame
      |> render_cell(region.row, region.col, label_w, label, :left, style)
      |> render_cell(region.row, region.col + label_w + 1, marker_w, marker, :left, style)

    frame = if is_focused?, do: Frame.set_focus_rect(frame, rect_of(region)), else: frame

    if open? and items != [] do
      push_dropdown(el, region, items, value)
    end

    frame
  end

  defp render_element(%Element{type: :vbox} = el, region, frame, focused) do
    constraints = Keyword.fetch!(el.opts, :constraints)
    rects = Layout.split(region, :vertical, constraints)
    render_children(el.children, rects, frame, focused)
  end

  defp render_element(%Element{type: :hbox} = el, region, frame, focused) do
    constraints = Keyword.fetch!(el.opts, :constraints)
    rects = Layout.split(region, :horizontal, constraints)
    render_children(el.children, rects, frame, focused)
  end

  defp render_element(%Element{type: :spacer}, _region, frame, _focused), do: frame

  defp render_element(%Element{type: :box, children: [child]} = el, region, frame, focused) do
    border_kind = Keyword.get(el.opts, :border, :single)
    {pt, pr, pb, pl} = normalize_padding(Keyword.get(el.opts, :padding, 0))

    border_style =
      el.opts
      |> Keyword.get(:border_style, Theme.get(:border))
      |> Style.from()
      |> maybe_focus_style(el, focused)

    fits_border? = border_kind != :none and region.w >= 2 and region.h >= 2
    border_w = if fits_border?, do: 1, else: 0

    frame =
      if fits_border? do
        draw_border(
          frame,
          region,
          border_kind,
          border_style,
          Keyword.get(el.opts, :title),
          Keyword.get(el.opts, :title_align, :left)
        )
      else
        frame
      end

    inner =
      Rect.new(
        region.row + border_w + pt,
        region.col + border_w + pl,
        max(0, region.w - 2 * border_w - pl - pr),
        max(0, region.h - 2 * border_w - pt - pb)
      )

    render_element(child, inner, frame, focused)
  end

  defp render_element(
         %Element{type: :overlay, children: [child, over]} = el,
         region,
         frame,
         focused
       ) do
    frame = render_element(child, region, frame, focused)

    w = min(Keyword.get(el.opts, :width) || region.w, region.w)
    h = min(Keyword.get(el.opts, :height) || region.h, region.h)
    anchor = Keyword.get(el.opts, :anchor, :center)
    over_region = anchor_region(region, anchor, w, h)

    render_element(over, over_region, frame, focused)
  end

  defp render_element(%Element{type: :viewport, children: [child]} = el, region, frame, focused) do
    declared_offset = Keyword.fetch!(el.opts, :offset)
    content_height = Keyword.fetch!(el.opts, :content_height)
    scrollbar? = Keyword.get(el.opts, :scrollbar, false)

    # R2: a focused viewport records its rendered visible height so the
    # runtime can compute correct page-step offsets when auto-routing
    # scroll keys. record_viewport/2 is a no-op for nil ids.
    if Keyword.get(el.opts, :focusable) == focused and not is_nil(focused) do
      WidgetMetrics.record_viewport(focused, region.h)
    end

    sb_col = if scrollbar?, do: 1, else: 0
    child_w = region.w - sb_col

    cond do
      child_w <= 0 ->
        frame

      content_height <= 0 ->
        frame

      true ->
        tall_frame = Frame.new(content_height, child_w)
        tall_region = %Rect{row: 0, col: 0, w: child_w, h: content_height}
        tall_frame = render_element(child, tall_region, tall_frame, focused)

        # Scroll-into-view: if the focused element is in our child's subtree
        # and outside the visible window, snap to bring it in. Model offset
        # is untouched — this is a render-time-only adjustment.
        effective_offset =
          scroll_into_view(declared_offset, region.h, content_height, tall_frame.focus_rect)

        frame =
          blit_viewport(
            tall_frame,
            frame,
            effective_offset,
            region.row,
            region.col,
            child_w,
            region.h
          )

        frame =
          remap_cursor(
            tall_frame.cursor,
            frame,
            effective_offset,
            region.row,
            region.col,
            child_w,
            region.h
          )

        if scrollbar? do
          sb_style =
            el.opts
            |> Keyword.get(:scrollbar_style, %Style{dim: true})
            |> Style.from()

          render_scrollbar(
            frame,
            region.row,
            region.col + child_w,
            region.h,
            effective_offset,
            content_height,
            sb_style
          )
        else
          frame
        end
    end
  end

  defp render_element(%Element{type: :table} = el, region, frame, focused) do
    columns = Keyword.fetch!(el.opts, :columns)
    rows = Keyword.fetch!(el.opts, :rows) |> Enum.to_list()
    row_id_fn = Keyword.fetch!(el.opts, :row_id)
    focused_row = Keyword.get(el.opts, :focused_row)
    selection = Keyword.get(el.opts, :selection, :none)
    show_header = Keyword.get(el.opts, :show_header, true)
    table_focused? = Keyword.get(el.opts, :focusable) == focused

    styles = table_styles(el.opts)

    col_rects = Layout.split(region, :horizontal, Enum.map(columns, & &1.width))

    header_h = if show_header, do: 1, else: 0
    body_height = max(0, region.h - header_h)

    frame =
      if show_header,
        do: render_header(frame, region.row, columns, col_rects, styles.header),
        else: frame

    visible = visible_rows(rows, focused_row, body_height, row_id_fn)

    visible
    |> Enum.with_index()
    |> Enum.reduce(frame, fn {row, idx}, acc ->
      y = region.row + header_h + idx
      row_id = row_id_fn.(row)
      style = row_style(row_id, idx, focused_row, selection, table_focused?, styles)
      render_row(acc, y, columns, col_rects, row, style)
    end)
  end

  # Resolve per-table style overrides up front so the row loop stays
  # cheap. Defaults preserve v0.3 behaviour exactly: header from theme,
  # body rows %Style{} unless focused/selected.
  defp table_styles(opts) do
    %{
      header: Keyword.get(opts, :header_style, Theme.get(:header)),
      row: Keyword.get(opts, :row_style, %Style{}),
      alt_row: Keyword.get(opts, :alt_row_style, nil),
      selected: Keyword.get(opts, :selected_style, Theme.get(:selection)),
      focus: Keyword.get(opts, :focus_style, Theme.get(:focus))
    }
  end

  defp anchor_region(region, :center, w, h) do
    Rect.new(
      region.row + div(max(0, region.h - h), 2),
      region.col + div(max(0, region.w - w), 2),
      w,
      h
    )
  end

  defp anchor_region(region, :top_left, w, h),
    do: Rect.new(region.row, region.col, w, h)

  defp anchor_region(region, :top_right, w, h),
    do: Rect.new(region.row, region.col + max(0, region.w - w), w, h)

  defp anchor_region(region, :bottom_left, w, h),
    do: Rect.new(region.row + max(0, region.h - h), region.col, w, h)

  defp anchor_region(region, :bottom_right, w, h),
    do:
      Rect.new(
        region.row + max(0, region.h - h),
        region.col + max(0, region.w - w),
        w,
        h
      )

  defp anchor_region(region, {row, col}, w, h),
    do: Rect.new(region.row + row, region.col + col, w, h)

  defp render_header(frame, y, columns, col_rects, header_style) do
    Enum.zip(columns, col_rects)
    |> Enum.reduce(frame, fn {%Column{} = col, rect}, f ->
      render_cell(f, y, rect.col, rect.w, col.title, col.align, header_style)
    end)
  end

  defp render_row(frame, y, columns, col_rects, row, style) do
    Enum.zip(columns, col_rects)
    |> Enum.reduce(frame, fn {%Column{} = col, rect}, f ->
      text = Column.render_value(col, row)
      render_cell(f, y, rect.col, rect.w, text, col.align, style)
    end)
  end

  # Render `left` at the leftmost cells of `region`, `right` at the rightmost,
  # background-fill the middle with `style`. Used by statusbar / keybar.
  defp render_lr_bar(frame, region, left, right, style) do
    left_w = Width.string_width(left)
    right_w = Width.string_width(right)

    {left_text, middle_pad, right_text} =
      cond do
        # Right doesn't fit at all
        right_w >= region.w ->
          {Width.slice(right, region.w), 0, ""}

        # Left + right overflow; truncate left
        left_w + right_w > region.w ->
          left_max = region.w - right_w
          {Width.slice(left, left_max), 0, right}

        true ->
          pad = region.w - left_w - right_w
          {left, pad, right}
      end

    frame
    |> Frame.write(region.row, region.col, left_text, style)
    |> Frame.write(
      region.row,
      region.col + Width.string_width(left_text),
      String.duplicate(" ", middle_pad),
      style
    )
    |> Frame.write(
      region.row,
      region.col + Width.string_width(left_text) + middle_pad,
      right_text,
      style
    )
  end

  defp format_binding({key, label}) do
    "[#{format_key(key)}] #{label}"
  end

  defp format_key(key) when is_integer(key), do: <<key::utf8>>
  defp format_key(key) when is_atom(key), do: Atom.to_string(key)
  defp format_key(key), do: to_string(key)

  defp render_tabs(
         frame,
         region,
         items,
         active,
         separator,
         inactive_style,
         active_style,
         sep_style
       ) do
    {_, _, frame} =
      Enum.reduce(items, {region.col, true, frame}, fn {id, label}, {col, first?, f} ->
        # Separator before each non-first tab
        f =
          if first? do
            f
          else
            Frame.write(f, region.row, col, separator, sep_style)
          end

        col = if first?, do: col, else: col + Width.string_width(separator)
        label_text = " #{label} "
        style = if id == active, do: active_style, else: inactive_style

        f = Frame.write(f, region.row, col, label_text, style)
        new_col = col + Width.string_width(label_text)
        {new_col, false, f}
      end)

    frame
  end

  defp default_tabs_active_style(true), do: Theme.get(:focus)
  defp default_tabs_active_style(false), do: Theme.get(:header)

  # Unfocused menus keep the highlight visible via :selection rather than
  # dropping to the base style — losing focus should not lose your place.
  defp default_menu_active_style(true), do: Theme.get(:focus)
  defp default_menu_active_style(false), do: Theme.get(:selection)

  # A select's open list is deferred rather than drawn in place: it has to cover
  # whatever the rest of the tree draws after the control, and the control can
  # sit anywhere in the layout. Floats also own the flipping, since only the top
  # level knows the screen bounds.
  defp push_dropdown(el, region, items, value) do
    highlight = Keyword.get(el.opts, :highlight, value)
    max_h = Keyword.get(el.opts, :max_height, 8)

    rows = items |> length() |> min(max_h)

    widest =
      items
      |> Enum.map(fn {_id, label} -> Width.string_width(label) end)
      |> Enum.max(fn -> 0 end)

    menu = %Element{
      type: :menu,
      opts: [items: items, active: highlight, style: Theme.get(:primary)],
      children: []
    }

    panel = %Element{
      type: :box,
      opts: [border: :single, border_style: Theme.get(:border)],
      children: [menu]
    }

    Floats.push(%{
      # region is already a %Rect{}; rect_of/1 flattens to the bare map
      # Frame.focus_rect wants, which is a different shape than Floats declares.
      anchor: region,
      # +2 on each axis for the border.
      w: max(widest + 2, region.w),
      h: rows + 2,
      element: panel
    })
  end

  defp mask(value) do
    value
    |> String.graphemes()
    |> Enum.map_join(fn _g -> "•" end)
  end

  defp render_cell(frame, y, x, width, text, align, style) when width > 0 do
    Frame.write(frame, y, x, align_text(to_string(text), width, align), style)
  end

  defp render_cell(frame, _y, _x, _width, _text, _align, _style), do: frame

  defp align_text(text, width, :left) do
    if Width.string_width(text) >= width,
      do: Width.slice(text, width),
      else: Width.pad_trailing(text, width)
  end

  defp align_text(text, width, :right) do
    if Width.string_width(text) >= width,
      do: Width.slice(text, width),
      else: Width.pad_leading(text, width)
  end

  defp align_text(text, width, :center) do
    sw = Width.string_width(text)

    if sw >= width do
      Width.slice(text, width)
    else
      total = width - sw
      left = div(total, 2)
      String.duplicate(" ", left) <> text <> String.duplicate(" ", total - left)
    end
  end

  # Resolve the style for one row, honouring per-table overrides plus
  # zebra striping. Priority: focused > selected > alt-row > default.
  # Defaults match v0.3 because styles.row is %Style{}, styles.alt_row
  # is nil (skip), styles.selected = Theme.get(:selection), and
  # styles.focus = Theme.get(:focus).
  defp row_style(id, _idx, id, _selection, _table_focused?, styles), do: styles.focus

  defp row_style(id, _idx, _focused, {:single, id}, _, styles), do: styles.selected

  defp row_style(id, idx, _focused, {:multi, %MapSet{} = set}, _, styles) do
    if MapSet.member?(set, id), do: styles.selected, else: base_row_style(idx, styles)
  end

  defp row_style(_id, idx, _focused, _selection, _, styles), do: base_row_style(idx, styles)

  defp base_row_style(_idx, %{alt_row: nil} = styles), do: styles.row
  defp base_row_style(idx, styles) when rem(idx, 2) == 1, do: styles.alt_row
  defp base_row_style(_idx, styles), do: styles.row

  defp visible_rows(_rows, _focused_id, body_height, _id_fn) when body_height <= 0, do: []

  defp visible_rows(rows, focused_id, body_height, id_fn) do
    num = length(rows)

    if num <= body_height do
      rows
    else
      idx = focused_index(rows, focused_id, id_fn)
      start = clamp(idx - div(body_height, 2), 0, num - body_height)
      rows |> Enum.drop(start) |> Enum.take(body_height)
    end
  end

  defp focused_index(_rows, nil, _id_fn), do: 0

  defp focused_index(rows, id, id_fn) do
    Enum.find_index(rows, &(id_fn.(&1) == id)) || 0
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp render_children(children, rects, frame, focused) do
    children
    |> Enum.zip(rects)
    |> Enum.reduce(frame, fn {child, rect}, acc -> render_element(child, rect, acc, focused) end)
  end

  defp maybe_focus_style(style, %Element{opts: opts}, focused) do
    case {Keyword.get(opts, :focusable), focused} do
      {nil, _} ->
        style

      {_, nil} ->
        style

      {id, id} ->
        Keyword.get(opts, :focus_style, Style.merge(style, Theme.get(:focus)))
        |> Style.from()

      _ ->
        style
    end
  end

  defp normalize_padding(n) when is_integer(n) and n >= 0, do: {n, n, n, n}

  defp normalize_padding({v, h}) when is_integer(v) and v >= 0 and is_integer(h) and h >= 0,
    do: {v, h, v, h}

  defp normalize_padding({t, r, b, l})
       when is_integer(t) and t >= 0 and is_integer(r) and r >= 0 and
              is_integer(b) and b >= 0 and is_integer(l) and l >= 0,
       do: {t, r, b, l}

  defp draw_border(frame, region, kind, style, title, title_align) do
    {tl, tr, bl, br, h, v} = Map.fetch!(@border_chars, kind)

    top = region.row
    bot = region.row + region.h - 1
    left = region.col
    right = region.col + region.w - 1
    inner_w = region.w - 2

    horizontal = if inner_w > 0, do: String.duplicate(h, inner_w), else: ""

    frame =
      frame
      |> Frame.write(top, left, tl, style)
      |> Frame.write(top, left + 1, horizontal, style)
      |> Frame.write(top, right, tr, style)
      |> Frame.write(bot, left, bl, style)
      |> Frame.write(bot, left + 1, horizontal, style)
      |> Frame.write(bot, right, br, style)

    frame =
      Enum.reduce((top + 1)..(bot - 1)//1, frame, fn r, f ->
        f
        |> Frame.write(r, left, v, style)
        |> Frame.write(r, right, v, style)
      end)

    case title do
      nil -> frame
      "" -> frame
      _ when inner_w <= 0 -> frame
      _ -> draw_title(frame, top, left + 1, inner_w, title, title_align, style)
    end
  end

  defp draw_title(frame, row, col, available_w, title, align, style) do
    text = " " <> title <> " "

    text =
      if Width.string_width(text) > available_w,
        do: Width.slice(text, available_w),
        else: text

    text_w = Width.string_width(text)

    offset =
      case align do
        :left -> 0
        :right -> max(0, available_w - text_w)
        :center -> div(max(0, available_w - text_w), 2)
      end

    Frame.write(frame, row, col + offset, text, style)
  end

  defp clip(text, max_cols) do
    if Width.string_width(text) <= max_cols, do: text, else: Width.slice(text, max_cols)
  end

  # -- Viewport helpers ------------------------------------------------------

  defp rect_of(%Rect{row: r, col: c, w: w, h: h}), do: %{row: r, col: c, w: w, h: h}

  defp scroll_into_view(offset, _vh, _ch, nil), do: offset

  defp scroll_into_view(offset, vh, ch, %{row: fr, h: fh}) do
    max_offset = max(0, ch - vh)

    adjusted =
      cond do
        # Focused element above viewport — snap top to focus row.
        fr < offset -> fr
        # Focused element below viewport — snap bottom to focus row + h.
        fr + fh > offset + vh -> fr + fh - vh
        true -> offset
      end

    adjusted |> max(0) |> min(max_offset)
  end

  defp remap_cursor(nil, frame, _off, _dr, _dc, _w, _h), do: frame

  defp remap_cursor({cr, cc}, frame, offset, dst_row, dst_col, w, h) do
    new_row = cr - offset + dst_row

    if cr - offset >= 0 and cr - offset < h and cc >= 0 and cc < w do
      Frame.set_cursor(frame, {new_row, dst_col + cc})
    else
      frame
    end
  end

  defp blit_viewport(src, dst, offset, dst_row, dst_col, w, h) do
    src_rows = src.buffer.rows

    Enum.reduce(0..(h - 1)//1, dst, fn dr, acc ->
      src_row = offset + dr

      if src_row < 0 or src_row >= src_rows do
        acc
      else
        blit_row(src, acc, src_row, dst_row + dr, dst_col, w)
      end
    end)
  end

  defp blit_row(src, dst, src_row, dst_row, dst_col, w) do
    Enum.reduce(0..(w - 1)//1, dst, fn dc, acc ->
      cell = Map.get(src.buffer.cells, {src_row, dc})

      if is_nil(cell) do
        acc
      else
        style = StyleTable.get(src.styles, cell.style_id)
        {new_id, new_styles} = StyleTable.intern(acc.styles, style)
        new_cell = %{cell | style_id: new_id}
        new_buffer = Buffer.put(acc.buffer, dst_row, dst_col + dc, new_cell)
        %{acc | buffer: new_buffer, styles: new_styles}
      end
    end)
  end

  defp render_scrollbar(frame, row, col, height, offset, content_height, style) do
    # Track background (single column of dim vertical bars).
    frame =
      Enum.reduce(0..(height - 1)//1, frame, fn dr, acc ->
        Frame.write(acc, row + dr, col, "│", style)
      end)

    # Thumb proportional to visible window.
    if content_height <= height do
      frame
    else
      thumb_h = max(1, div(height * height, content_height))
      max_off = max(1, content_height - height)
      thumb_top = div(offset * (height - thumb_h), max_off)

      Enum.reduce(0..(thumb_h - 1)//1, frame, fn dr, acc ->
        Frame.write(acc, row + thumb_top + dr, col, "█", style)
      end)
    end
  end
end
