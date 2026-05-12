defmodule Harlock.Layout.Rect do
  @moduledoc false
  # A rectangle in cell coordinates. (row, col) is the top-left; w spans
  # cols rightward, h spans rows downward. All values are non-negative
  # integers; an empty rect has w == 0 or h == 0.

  defstruct row: 0, col: 0, w: 0, h: 0

  @type t :: %__MODULE__{
          row: non_neg_integer(),
          col: non_neg_integer(),
          w: non_neg_integer(),
          h: non_neg_integer()
        }

  @spec new(non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def new(row, col, w, h), do: %__MODULE__{row: row, col: col, w: w, h: h}

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{w: w, h: h}), do: w == 0 or h == 0
end
