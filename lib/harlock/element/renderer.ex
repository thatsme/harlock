defmodule Harlock.Element.Renderer do
  @moduledoc false
  # Walks an element tree, applying the layout solver to vbox/hbox, and lays
  # cells down into a Frame. Pure function — no I/O.

  alias Harlock.{Element, Layout}
  alias Harlock.Element.Column
  alias Harlock.Layout.Rect
  alias Harlock.Render.{Frame, Style}

  @spec render(Element.t(), non_neg_integer(), non_neg_integer(), any()) :: Frame.t()
  def render(%Element{} = root, rows, cols, focused \\ nil) do
    frame = Frame.new(rows, cols)
    region = Rect.new(0, 0, cols, rows)
    render_element(root, region, frame, focused)
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

  defp render_element(%Element{type: :overlay, children: [child, over]} = el, region, frame, focused) do
    frame = render_element(child, region, frame, focused)

    w = min(Keyword.get(el.opts, :width) || region.w, region.w)
    h = min(Keyword.get(el.opts, :height) || region.h, region.h)
    anchor = Keyword.get(el.opts, :anchor, :center)
    over_region = anchor_region(region, anchor, w, h)

    render_element(over, over_region, frame, focused)
  end

  defp render_element(%Element{type: :table} = el, region, frame, focused) do
    columns = Keyword.fetch!(el.opts, :columns)
    rows = Keyword.fetch!(el.opts, :rows) |> Enum.to_list()
    row_id_fn = Keyword.fetch!(el.opts, :row_id)
    focused_row = Keyword.get(el.opts, :focused_row)
    selection = Keyword.get(el.opts, :selection, :none)
    show_header = Keyword.get(el.opts, :show_header, true)
    table_focused? = Keyword.get(el.opts, :focusable) == focused

    col_rects = Layout.split(region, :horizontal, Enum.map(columns, & &1.width))

    header_h = if show_header, do: 1, else: 0
    body_height = max(0, region.h - header_h)

    frame =
      if show_header,
        do: render_header(frame, region.row, columns, col_rects),
        else: frame

    visible = visible_rows(rows, focused_row, body_height, row_id_fn)

    visible
    |> Enum.with_index()
    |> Enum.reduce(frame, fn {row, idx}, acc ->
      y = region.row + header_h + idx
      row_id = row_id_fn.(row)
      style = row_style(row_id, focused_row, selection, table_focused?)
      render_row(acc, y, columns, col_rects, row, style)
    end)
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
    do: Rect.new(
      region.row + max(0, region.h - h),
      region.col + max(0, region.w - w),
      w,
      h
    )

  defp anchor_region(region, {row, col}, w, h),
    do: Rect.new(region.row + row, region.col + col, w, h)

  defp render_header(frame, y, columns, col_rects) do
    header_style = %Style{bold: true}

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

  defp render_cell(frame, y, x, width, text, align, style) when width > 0 do
    Frame.write(frame, y, x, align_text(to_string(text), width, align), style)
  end

  defp render_cell(frame, _y, _x, _width, _text, _align, _style), do: frame

  defp align_text(text, width, :left) do
    if String.length(text) >= width,
      do: String.slice(text, 0, width),
      else: String.pad_trailing(text, width)
  end

  defp align_text(text, width, :right) do
    if String.length(text) >= width,
      do: String.slice(text, 0, width),
      else: String.pad_leading(text, width)
  end

  defp align_text(text, width, :center) do
    len = String.length(text)

    if len >= width do
      String.slice(text, 0, width)
    else
      total = width - len
      left = div(total, 2)
      String.duplicate(" ", left) <> text <> String.duplicate(" ", total - left)
    end
  end

  defp row_style(id, id, _selection, true), do: %Style{reverse: true}
  defp row_style(id, id, _selection, false), do: %Style{bold: true}

  defp row_style(id, _focused, {:single, id}, _), do: %Style{bg: :cyan}

  defp row_style(id, _focused, {:multi, %MapSet{} = set}, _) do
    if MapSet.member?(set, id), do: %Style{bg: :cyan}, else: %Style{}
  end

  defp row_style(_id, _focused, _selection, _), do: %Style{}

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
      {nil, _} -> style
      {_, nil} -> style
      {id, id} -> Keyword.get(opts, :focus_style, %{style | reverse: true}) |> Style.from()
      _ -> style
    end
  end

  defp clip(text, max_cols) do
    # String.slice is grapheme-aware; for v0.1 single-cell-per-codepoint this
    # is correct. Wide grapheme support (CJK, emoji) arrives in v0.2.
    if String.length(text) <= max_cols, do: text, else: String.slice(text, 0, max_cols)
  end
end
