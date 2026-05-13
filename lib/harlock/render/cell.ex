defmodule Harlock.Render.Cell do
  @moduledoc """
  A single terminal cell.

    * `:char` — a codepoint integer, a grapheme binary, `nil` (blank),
      or `:continuation` (the second cell of a wide grapheme).
    * `:style_id` — integer index into the frame's internal style table.

  Single-codepoint graphemes (the common case — ASCII, Latin-1 NFC)
  take the integer fast path. Multi-codepoint graphemes (NFD
  diacritics, ZWJ sequences, regional-indicator flags) are stored as
  binaries so the grapheme is rendered verbatim. Wide graphemes
  occupy two cells: the grapheme at `(row, col)` and `:continuation`
  at `(row, col + 1)`.

  You'll see cells when inspecting a render via `Harlock.Test.cells/1`.
  """

  defstruct char: nil, style_id: 0

  @type char_value :: non_neg_integer() | String.t() | nil | :continuation
  @type t :: %__MODULE__{char: char_value(), style_id: non_neg_integer()}

  @spec blank(non_neg_integer()) :: t()
  def blank(style_id \\ 0), do: %__MODULE__{char: nil, style_id: style_id}

  @spec new(char_value(), non_neg_integer()) :: t()
  def new(char, style_id), do: %__MODULE__{char: char, style_id: style_id}
end
