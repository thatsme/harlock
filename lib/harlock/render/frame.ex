defmodule Harlock.Render.Frame do
  @moduledoc false
  # A frame bundles a Buffer with its StyleTable. The renderer layers above
  # (layout solver, element renderers) call Frame.write/4 to lay down text;
  # the diff renderer takes a previous Frame plus a new Frame and produces
  # the ANSI bytes to transition between them.
  #
  # write/4 walks graphemes, not codepoints — combining marks attach to
  # their base in a single cell, and width-2 graphemes (CJK, emoji)
  # occupy two cells with `:continuation` in the second.

  alias Harlock.Render.Buffer
  alias Harlock.Render.Cell
  alias Harlock.Render.Style
  alias Harlock.Render.StyleTable
  alias Harlock.Width

  defstruct buffer: nil, styles: nil, cursor: nil, focus_rect: nil

  @type t :: %__MODULE__{
          buffer: Buffer.t(),
          styles: StyleTable.t(),
          cursor: {non_neg_integer(), non_neg_integer()} | nil,
          focus_rect:
            %{
              row: non_neg_integer(),
              col: non_neg_integer(),
              w: non_neg_integer(),
              h: non_neg_integer()
            }
            | nil
        }

  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(rows, cols) do
    %__MODULE__{buffer: Buffer.new(rows, cols), styles: StyleTable.new(), cursor: nil}
  end

  @doc "Position the terminal cursor at (row, col), or hide it with nil."
  @spec set_cursor(t(), {non_neg_integer(), non_neg_integer()} | nil) :: t()
  def set_cursor(%__MODULE__{} = frame, cursor), do: %{frame | cursor: cursor}

  @doc """
  Record the bounding rectangle of the currently-focused element. Used by
  `viewport` to scroll the focused element into view at render time.
  Overwritten on each call so the innermost match wins when nested.
  """
  @spec set_focus_rect(t(), map() | nil) :: t()
  def set_focus_rect(%__MODULE__{} = frame, rect), do: %{frame | focus_rect: rect}

  @doc """
  Write `text` into the frame starting at (row, col), one codepoint per cell,
  using `style`. Text overflowing the right edge of the buffer is clipped.
  Newlines and other control codes are not interpreted — callers are expected
  to position each line themselves.

  Returns the updated frame.
  """
  @spec write(t(), non_neg_integer(), non_neg_integer(), String.t(), Style.t() | keyword()) :: t()
  def write(%__MODULE__{} = frame, row, col, text, style \\ %Style{}) do
    {style_id, styles} = StyleTable.intern(frame.styles, Style.from(style))
    buffer = put_text(frame.buffer, row, col, text, style_id)
    %{frame | buffer: buffer, styles: styles}
  end

  @doc """
  Fill the rectangle (row, col) — (row + h - 1, col + w - 1) with `cell_char`
  and `style`. Used for backgrounds, separators, the empty space inside
  boxes, etc. `cell_char` is a codepoint; pass `?\s` for an actual space.
  """
  @spec fill(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          char(),
          Style.t() | keyword()
        ) :: t()
  def fill(%__MODULE__{} = frame, row, col, w, h, cell_char, style \\ %Style{}) do
    {style_id, styles} = StyleTable.intern(frame.styles, Style.from(style))

    buffer =
      Enum.reduce(0..(h - 1)//1, frame.buffer, fn dr, b1 ->
        Enum.reduce(0..(w - 1)//1, b1, fn dc, b2 ->
          Buffer.put(b2, row + dr, col + dc, Cell.new(cell_char, style_id))
        end)
      end)

    %{frame | buffer: buffer, styles: styles}
  end

  defp put_text(buffer, row, col, text, style_id) do
    {buffer, _col} =
      text
      |> String.graphemes()
      |> Enum.reduce_while({buffer, col}, fn grapheme, {buf, c} ->
        case place_grapheme(buf, row, c, grapheme, style_id) do
          {:ok, new_buf, new_col} -> {:cont, {new_buf, new_col}}
          :stop -> {:halt, {buf, c}}
        end
      end)

    buffer
  end

  defp place_grapheme(buffer, row, col, grapheme, style_id) do
    case Width.width(grapheme) do
      0 ->
        # Zero-width grapheme (combining mark / format char with no base in
        # this position). Skip — best-effort; graphemes from String.graphemes/1
        # normally include their base.
        {:ok, buffer, col}

      1 ->
        if col >= buffer.cols do
          :stop
        else
          {:ok, Buffer.put(buffer, row, col, Cell.new(char_for(grapheme), style_id)), col + 1}
        end

      2 ->
        cond do
          col >= buffer.cols ->
            :stop

          col + 1 >= buffer.cols ->
            # Only one column left; the wide grapheme can't fit. Drop it
            # rather than splitting.
            :stop

          true ->
            buffer =
              buffer
              |> Buffer.put(row, col, Cell.new(char_for(grapheme), style_id))
              |> Buffer.put(row, col + 1, Cell.new(:continuation, style_id))

            {:ok, buffer, col + 2}
        end
    end
  end

  # Single-codepoint graphemes take the integer fast path; multi-codepoint
  # graphemes stay as binaries so they render verbatim.
  defp char_for(grapheme) do
    case String.to_charlist(grapheme) do
      [cp] -> cp
      _ -> grapheme
    end
  end
end
