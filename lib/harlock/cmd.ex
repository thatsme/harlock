defmodule Harlock.Cmd do
  @moduledoc false
  # Side-effect descriptors returned from `update/2`. v0.1 is a stub: the
  # runtime only processes `:none`. Real async execution via Task.Supervisor
  # arrives once the sysmon demo demands it.

  @type t :: :none | {:fun, (-> any())} | {:batch, [t()]}

  @spec none() :: t()
  def none, do: :none

  @spec from((-> any())) :: t()
  def from(fun) when is_function(fun, 0), do: {:fun, fun}

  @spec batch([t()]) :: t()
  def batch(cmds) when is_list(cmds), do: {:batch, cmds}
end
