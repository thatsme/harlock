defmodule Harlock.Render.StyleTable do
  @moduledoc false
  # Interns Style structs into small integer IDs so cell buffers stay cheap.
  #
  # In v0.1 the table is cleared every frame (Frame.new/2 creates a fresh
  # one). This means dynamic styles can't leak. If profiling later shows that
  # most styles persist across frames we can add a "carry over from previous
  # frame" set without changing the public API.

  alias Harlock.Render.Style

  defstruct by_id: %{0 => %Style{}}, by_style: %{%Style{} => 0}, next_id: 1

  @type id :: non_neg_integer()
  @type t :: %__MODULE__{
          by_id: %{id() => Style.t()},
          by_style: %{Style.t() => id()},
          next_id: id()
        }

  @doc "Returns a fresh table containing only the default style at id 0."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "The reserved id for the default (empty) style."
  @spec default_id() :: id()
  def default_id, do: 0

  @doc """
  Look up an id for `style`, allocating one if not yet present. Returns
  `{id, updated_table}`.
  """
  @spec intern(t(), Style.t()) :: {id(), t()}
  def intern(%__MODULE__{} = table, %Style{} = style) do
    case Map.fetch(table.by_style, style) do
      {:ok, id} ->
        {id, table}

      :error ->
        id = table.next_id

        {id,
         %__MODULE__{
           by_id: Map.put(table.by_id, id, style),
           by_style: Map.put(table.by_style, style, id),
           next_id: id + 1
         }}
    end
  end

  @spec get(t(), id()) :: Style.t()
  def get(%__MODULE__{by_id: by_id}, id), do: Map.fetch!(by_id, id)
end
