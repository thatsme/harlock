defmodule Harlock.Element.Focusables do
  @moduledoc false
  # DFS traversal collecting focusable ids from an element tree. Returns
  # `{ids, traps}`:
  #   * `ids` — every focusable id in render order (top-to-bottom,
  #     left-to-right within siblings)
  #   * `traps` — for each subtree marked `focus_trap: true`, the list of
  #     focusable ids within it. Innermost traps are listed last in tree
  #     order so the runtime can pick the deepest active trap by walking
  #     the list backward.

  alias Harlock.Element

  @type id :: any()

  @spec collect(Element.t()) :: {[id()], [[id()]]}
  def collect(%Element{} = root) do
    {collect_ids(root), collect_traps(root)}
  end

  defp collect_ids(%Element{} = el) do
    here =
      case Keyword.get(el.opts, :focusable) do
        nil -> []
        id -> [id]
      end

    here ++ Enum.flat_map(el.children, &collect_ids/1)
  end

  defp collect_traps(%Element{} = el) do
    here =
      if Keyword.get(el.opts, :focus_trap) == true do
        [collect_ids(el)]
      else
        []
      end

    here ++ Enum.flat_map(el.children, &collect_traps/1)
  end
end
