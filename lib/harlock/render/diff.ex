defmodule Harlock.Render.Diff do
  @moduledoc false
  # Produces the minimal ANSI byte stream to transition the terminal from
  # `prev` (what's on screen) to `curr` (what should be).
  #
  # Algorithm:
  #   walk every cell in row-major order
  #   if the cell matches prev → skip
  #   else → emit a cursor move if we aren't already at (row, col),
  #          emit an SGR change if the style differs from what's set,
  #          emit the character (codepoint as utf-8 bytes)
  #
  # We don't try to coalesce moves further; modern terminals process
  # `\e[<r>;<c>H` faster than we can avoid emitting them. Style transitions
  # are full resets via Style.to_sgr/1, which is more bytes but simpler
  # bookkeeping. Both are optimization opportunities for v0.2 if profiling
  # demands.

  alias Harlock.Render.{Ansi, Buffer, Cell, Frame, Style, StyleTable}
  alias Harlock.Terminal.Ansi, as: AnsiTerm

  @type op_state :: %{
          cursor: {non_neg_integer(), non_neg_integer()} | nil,
          last_style: Style.t() | nil
        }

  @doc """
  Returns the iolist of ANSI bytes that, when written to the terminal, will
  transform what's currently displayed (`prev`) into what `curr` describes.
  If `prev` is `nil`, treats the screen as blank — useful for the first
  frame.
  """
  @spec diff(Frame.t() | nil, Frame.t()) :: iodata()
  def diff(nil, %Frame{} = curr) do
    diff_buffer(blank_like(curr), curr.buffer, curr.styles)
  end

  def diff(%Frame{} = prev, %Frame{} = curr) do
    if prev.buffer.rows == curr.buffer.rows and prev.buffer.cols == curr.buffer.cols do
      diff_with_prev(prev, curr)
    else
      # Dimensions changed (resize) — bail to full redraw.
      [AnsiTerm.clear_screen(), diff_buffer(blank_like(curr), curr.buffer, curr.styles)]
    end
  end

  defp diff_with_prev(prev, curr) do
    # Style ids are local to each frame's table, so we can't compare ids
    # directly across frames. Resolve to actual Style structs when comparing.
    diff_resolved(prev.buffer, prev.styles, curr.buffer, curr.styles)
  end

  defp diff_resolved(prev_buf, prev_styles, curr_buf, curr_styles) do
    {ops, _state} =
      Enum.reduce(positions(curr_buf), {[], initial_state()}, fn {row, col}, {ops, state} ->
        prev_cell = Buffer.get(prev_buf, row, col)
        curr_cell = Buffer.get(curr_buf, row, col)

        prev_style = StyleTable.get(prev_styles, prev_cell.style_id)
        curr_style = StyleTable.get(curr_styles, curr_cell.style_id)

        if same_render?(prev_cell, prev_style, curr_cell, curr_style) do
          {ops, state}
        else
          emit(ops, state, row, col, curr_cell, curr_style)
        end
      end)

    Enum.reverse(ops)
  end

  defp diff_buffer(prev_buf, curr_buf, curr_styles) do
    {ops, _state} =
      Enum.reduce(positions(curr_buf), {[], initial_state()}, fn {row, col}, {ops, state} ->
        prev_cell = Buffer.get(prev_buf, row, col)
        curr_cell = Buffer.get(curr_buf, row, col)

        curr_style = StyleTable.get(curr_styles, curr_cell.style_id)

        if same_render?(prev_cell, %Style{}, curr_cell, curr_style) do
          {ops, state}
        else
          emit(ops, state, row, col, curr_cell, curr_style)
        end
      end)

    Enum.reverse(ops)
  end

  defp emit(ops, state, row, col, cell, style) do
    ops = maybe_move(ops, state.cursor, row, col)
    ops = maybe_style(ops, state.last_style, style)
    ops = [render_char(cell.char) | ops]
    {ops, %{state | cursor: {row, col + 1}, last_style: style}}
  end

  defp maybe_move(ops, {row, col}, row, col), do: ops
  defp maybe_move(ops, _other, row, col), do: [AnsiTerm.move(row, col) | ops]

  defp maybe_style(ops, %Style{} = same, %Style{} = same), do: ops
  defp maybe_style(ops, _prev, curr), do: [Style.to_sgr(curr) | ops]

  defp render_char(nil), do: " "
  defp render_char(:continuation), do: []
  defp render_char(cp) when is_integer(cp), do: <<cp::utf8>>

  defp same_render?(%Cell{char: c1}, s1, %Cell{char: c2}, s2) do
    normalize_char(c1) == normalize_char(c2) and s1 == s2
  end

  defp normalize_char(nil), do: ?\s
  defp normalize_char(cp), do: cp

  defp positions(%Buffer{rows: rows, cols: cols}) do
    for r <- 0..(rows - 1)//1, c <- 0..(cols - 1)//1, do: {r, c}
  end

  defp blank_like(%Frame{buffer: %Buffer{rows: r, cols: c}}), do: Buffer.new(r, c)

  defp initial_state, do: %{cursor: nil, last_style: nil}

  # Suppress unused alias warning — kept for documentation of layering.
  _ = Ansi
end
