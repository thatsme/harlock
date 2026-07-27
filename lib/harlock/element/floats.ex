defmodule Harlock.Element.Floats do
  @moduledoc false
  # Process-dictionary scratchpad for deferred draws — content that must land
  # on top of whatever the rest of the tree draws, regardless of where its
  # element sits in that tree.
  #
  # `overlay` does not need this: it holds both layers as children and draws
  # them in order, so its own subtree establishes the z-order. A dropdown
  # cannot work that way. It is anchored to a control buried somewhere in the
  # layout, and every sibling rendered after that control would draw over it.
  #
  # So the renderer records the panel here during the walk and draws it
  # afterwards. Recording order is draw order, which is what makes nesting
  # work: a submenu opened from a menu is pushed later and therefore drawn
  # later, giving a stack without anything having to track depth.
  #
  # Mirrors Harlock.Element.WidgetMetrics: the renderer clears before a walk
  # and drains after it, and the whole thing is scoped to the rendering
  # process.

  @key :harlock_floats

  @type float_spec :: %{
          anchor: Harlock.Layout.Rect.t(),
          w: non_neg_integer(),
          h: non_neg_integer(),
          element: Harlock.Element.t()
        }

  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @doc "Record a panel to draw after the tree walk. Later pushes draw later."
  @spec push(float_spec()) :: :ok
  def push(%{anchor: _, w: _, h: _, element: _} = spec) do
    Process.put(@key, [spec | Process.get(@key, [])])
    :ok
  end

  @doc "Take everything recorded so far, in push order, and reset."
  @spec drain() :: [float_spec()]
  def drain do
    floats = @key |> Process.get([]) |> Enum.reverse()
    Process.delete(@key)
    floats
  end
end
