defmodule Harlock.Render.Cell do
  @moduledoc false
  # A single terminal cell. `char` is a codepoint or nil (blank); `style_id` is
  # an integer pointing into the frame's StyleTable. Keeping the per-cell
  # payload to two integers is what lets us hold a full-screen buffer cheaply.
  #
  # Wide grapheme handling (CJK, emoji) is v0.2: those occupy 2 cells, with
  # the second cell marked `:continuation`. The shape is already laid out
  # to extend (`char` can become `:continuation`).

  defstruct char: nil, style_id: 0

  @type char_value :: non_neg_integer() | nil | :continuation
  @type t :: %__MODULE__{char: char_value(), style_id: non_neg_integer()}

  @spec blank(non_neg_integer()) :: t()
  def blank(style_id \\ 0), do: %__MODULE__{char: nil, style_id: style_id}

  @spec new(char_value(), non_neg_integer()) :: t()
  def new(char, style_id), do: %__MODULE__{char: char, style_id: style_id}
end
