defmodule Harlock.Render.Buffer do
  @moduledoc false
  # A 2D grid of cells of fixed dimensions. Cells are stored in a Map keyed by
  # {row, col}; missing keys behave as blanks. Map representation keeps
  # construction cheap (no need to pre-fill every cell) and survives sparse
  # frames where most cells are blank.

  alias Harlock.Render.Cell

  defstruct [:rows, :cols, cells: %{}]

  @type t :: %__MODULE__{
          rows: non_neg_integer(),
          cols: non_neg_integer(),
          cells: %{{non_neg_integer(), non_neg_integer()} => Cell.t()}
        }

  @spec new(non_neg_integer(), non_neg_integer()) :: t()
  def new(rows, cols) when rows >= 0 and cols >= 0 do
    %__MODULE__{rows: rows, cols: cols}
  end

  @spec put(t(), non_neg_integer(), non_neg_integer(), Cell.t()) :: t()
  def put(%__MODULE__{rows: rows, cols: cols} = buf, row, col, %Cell{} = cell)
      when row >= 0 and row < rows and col >= 0 and col < cols do
    %{buf | cells: Map.put(buf.cells, {row, col}, cell)}
  end

  def put(%__MODULE__{} = buf, _row, _col, _cell), do: buf

  @spec get(t(), non_neg_integer(), non_neg_integer()) :: Cell.t()
  def get(%__MODULE__{cells: cells}, row, col) do
    Map.get(cells, {row, col}, Cell.blank())
  end

  @doc """
  Enumerate every cell in render order (row-major, top-left to bottom-right),
  yielding `{row, col, cell}` tuples. Missing entries are surfaced as blanks
  so the diff renderer can compare positions without checking presence.
  """
  @spec each(t(), ({non_neg_integer(), non_neg_integer(), Cell.t()} -> any())) :: :ok
  def each(%__MODULE__{rows: rows, cols: cols} = buf, fun) do
    for row <- 0..(rows - 1)//1, col <- 0..(cols - 1)//1 do
      fun.({row, col, get(buf, row, col)})
    end

    :ok
  end
end
