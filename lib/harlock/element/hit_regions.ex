defmodule Harlock.Element.HitRegions do
  @moduledoc false
  # Process-dictionary scratchpad recording where focusable elements landed on
  # screen, so the runtime can resolve a mouse position to an element. Layout
  # only happens inside the renderer; nothing else knows these rectangles.
  #
  # Regions are kept in draw order, and later means on top: a child is drawn
  # after its parent, an overlay's foreground after its background, a float
  # after the whole tree. The topmost region containing a point is the one
  # that was hit.
  #
  # A region can name a part of its element — {:row, row_id} in a table,
  # {:marker, node_id} on a tree node's expand marker — recorded as the widget
  # draws that part, after the element's own region and so on top of it. A
  # click resolves to the element and, when it landed on one, the part.
  #
  # A region's id is nil for an occluder: an overlay panel or a float, which
  # covers whatever was drawn beneath it without being focusable itself. A
  # click on a modal's blank space must not reach the widget under it.
  #
  # A viewport draws its child into a taller off-screen frame and copies the
  # visible slice across. Regions recorded while drawing that child are in the
  # tall frame's coordinates, so the viewport collects them in a scope and adds
  # them back translated and clipped, via scoped/1 and add/1.
  #
  # Mirrors Harlock.Element.WidgetMetrics and Harlock.Element.Floats: the
  # renderer clears before a walk, the runtime consumes after it.

  alias Harlock.Layout.Rect

  @key :harlock_hit_regions

  @type region :: %{id: any(), rect: Rect.t(), part: any()}

  @spec clear() :: :ok
  def clear do
    Process.put(@key, [[]])
    :ok
  end

  @doc """
  Record `rect` for focus id `id`, or an occluder when `id` is nil. `part`
  names the part of the element the rect covers; nil for the element itself.
  """
  @spec record(any(), Rect.t(), any()) :: :ok
  def record(id, %Rect{} = rect, part \\ nil), do: add([%{id: id, rect: rect, part: part}])

  @doc "Append already-built regions, in draw order, to the current scope."
  @spec add([region()]) :: :ok
  def add(regions) do
    [scope | rest] = Process.get(@key, [[]])
    Process.put(@key, [Enum.reverse(regions, scope) | rest])
    :ok
  end

  @doc "Run `fun` collecting the regions it records separately; returns them, in draw order."
  @spec scoped((-> result)) :: {result, [region()]} when result: any()
  def scoped(fun) do
    Process.put(@key, [[] | Process.get(@key, [[]])])
    result = fun.()
    [scope | rest] = Process.get(@key)
    Process.put(@key, rest)
    {result, Enum.reverse(scope)}
  end

  @doc "All regions recorded since clear/0, in draw order, and reset."
  @spec consume() :: [region()]
  def consume do
    regions = @key |> Process.get([[]]) |> List.last() |> Enum.reverse()
    Process.delete(@key)
    regions
  end

  @doc "The topmost region containing 0-indexed `{row, col}`: its id and part."
  @spec at([region()], non_neg_integer(), non_neg_integer()) :: {:hit, any(), any()} | :miss
  def at(regions, row, col) do
    regions
    |> Enum.reverse()
    |> Enum.find(&contains?(&1.rect, row, col))
    |> case do
      nil -> :miss
      %{id: id, part: part} -> {:hit, id, part}
    end
  end

  @doc "The rect of `id`'s own region (not a part), topmost if recorded more than once."
  @spec rect_of([region()], any()) :: Rect.t() | nil
  def rect_of(regions, id) do
    regions
    |> Enum.filter(&(&1.id == id and &1.part == nil))
    |> List.last()
    |> case do
      nil -> nil
      %{rect: rect} -> rect
    end
  end

  @doc "Shift regions by `{drow, dcol}` and clip them to `clip`, dropping any left empty."
  @spec translate_and_clip([region()], integer(), integer(), Rect.t()) :: [region()]
  def translate_and_clip(regions, drow, dcol, %Rect{} = clip) do
    Enum.flat_map(regions, fn %{rect: r} = region ->
      top = max(r.row + drow, clip.row)
      left = max(r.col + dcol, clip.col)
      bottom = min(r.row + drow + r.h, clip.row + clip.h)
      right = min(r.col + dcol + r.w, clip.col + clip.w)

      if bottom > top and right > left,
        do: [%{region | rect: Rect.new(top, left, right - left, bottom - top)}],
        else: []
    end)
  end

  defp contains?(%Rect{row: r, col: c, w: w, h: h}, row, col),
    do: row >= r and row < r + h and col >= c and col < c + w
end
