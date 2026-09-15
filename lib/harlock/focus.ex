defmodule Harlock.Focus do
  @moduledoc """
  Read access to focus state during `view/1` and `update/2` callbacks.

  Focus state itself lives in the runtime; this module exposes it via the
  process dictionary, set by the runtime immediately before invoking app
  callbacks. Called from outside a Harlock callback it has no state to read.

  Focus is read-only from an app. It starts on the first focusable element and
  moves with Tab / Shift-Tab, mouse clicks, a focus trap opening or closing, and
  the focused element leaving the view. Each move is delivered to `update/2` as
  `{:harlock_focus, from, to}` — see "Focus changes" in `Harlock.App`.
  """

  @key :harlock_focus

  @doc """
  The id of the currently focused element, or `nil` if no focusable element
  exists. Call this from inside `update/2` or `view/1`.

  In `view/1` it is the focus the frame is drawn with. Focus is settled from
  the tree the view returns, so when settling moves it — the first frame, a
  trap opening or closing, the focused element going away — the runtime calls
  `view/1` a second time with the settled focus, and draws that tree.
  """
  @spec current() :: any()
  def current, do: Process.get(@key)

  @doc false
  # Used by the runtime to set context before invoking user callbacks.
  def __set__(id), do: Process.put(@key, id)

  @doc false
  def __clear__, do: Process.delete(@key)
end
