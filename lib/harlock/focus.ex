defmodule Harlock.Focus do
  @moduledoc """
  Read access to focus state during `view/1` and `update/2` callbacks.

  Focus state itself lives in the runtime; this module exposes it via the
  process dictionary, set by the runtime immediately before invoking app
  callbacks. Don't try to call this from outside a Harlock callback —
  there's no global state to read.

  Mutation (setting focus, advancing it manually) returns a `Cmd` to the
  runtime. v0.1 ships `Cmd.focus/1`; richer programmatic control arrives
  alongside the full Cmd executor.
  """

  @key :harlock_focus

  @doc """
  The id of the currently focused element, or `nil` if no focusable element
  exists. Call this from inside `update/2` or `view/1`.
  """
  @spec current() :: any()
  def current, do: Process.get(@key)

  @doc false
  # Used by the runtime to set context before invoking user callbacks.
  def __set__(id), do: Process.put(@key, id)

  @doc false
  def __clear__, do: Process.delete(@key)
end
