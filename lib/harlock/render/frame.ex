defmodule Harlock.Render.Frame do
  @moduledoc false
  # A frame bundles a Buffer with its StyleTable. The renderer layers above
  # (layout solver, element renderers) call Frame.write/4 to lay down text;
  # the diff renderer takes a previous Frame plus a new Frame and produces
  # the ANSI bytes to transition between them.

  alias Harlock.Render.{Buffer, Cell, Style, StyleTable}

  defstruct [:buffer, :styles]

  @type t :: %__MODULE__{buffer: Buffer.t(), styles: StyleTable.t()}

  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(rows, cols) do
    %__MODULE__{buffer: Buffer.new(rows, cols), styles: StyleTable.new()}
  end

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

  defp put_text(buffer, _row, _col, "", _style_id), do: buffer

  defp put_text(buffer, row, col, <<cp::utf8, rest::binary>>, style_id) do
    buffer
    |> Buffer.put(row, col, Cell.new(cp, style_id))
    |> put_text(row, col + 1, rest, style_id)
  end

  # Drop any non-utf8 trailing bytes silently — they shouldn't appear in
  # well-formed input but we'd rather render a clipped string than crash.
  defp put_text(buffer, _row, _col, _, _style_id), do: buffer
end
