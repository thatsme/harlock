defmodule Harlock.Element.Focusables do
  @moduledoc false
  # DFS traversal collecting everything the runtime needs from an element
  # tree for focus and R2 widget-key auto-routing. Returns:
  #
  #   {ids, traps, routed_widgets}
  #
  # * `ids` — every focusable id in render order (top-to-bottom,
  #   left-to-right within siblings).
  # * `traps` — for each subtree marked `focus_trap: true`, the list of
  #   focusable ids within it (including the trap container's own id and
  #   any ids inside nested traps). Innermost traps are listed last in
  #   tree order so the runtime can pick the deepest active trap by
  #   walking the list backward.
  # * `routed_widgets` — `%{focus_id => element}` for focusable elements
  #   whose type opts in to R2 auto-routing (`@auto_routed_types` below,
  #   which is the single source of truth — don't restate the list here)
  #   and that have not explicitly set `handle_keys: false`. Used by
  #   `Harlock.App.Runtime` to look up the focused widget at key-dispatch
  #   time without re-walking the tree.
  #
  # The id and routed-widget collection are folded into one walk
  # (`collect_ids_and_widgets/2`); traps remain a separate walk because
  # their semantics (each trap captures the *whole* subtree, including
  # nested traps' ids) make folding harder than it's worth.

  alias Harlock.Element

  @type id :: any()

  @auto_routed_types [
    :viewport,
    :tabs,
    :text_input,
    :textarea,
    :menu,
    :select,
    :tree,
    :table
  ]

  @spec collect(Element.t()) :: {[id()], [[id()]], %{id() => Element.t()}}
  def collect(%Element{} = root) do
    {ids, widgets} = collect_ids_and_widgets(root, {[], %{}})
    {Enum.reverse(ids), collect_traps(root), widgets}
  end

  defp collect_ids_and_widgets(%Element{} = el, {ids, widgets}) do
    {ids, widgets} =
      case Keyword.get(el.opts, :focusable) do
        nil ->
          {ids, widgets}

        focus_id ->
          ids = [focus_id | ids]

          widgets =
            if el.type in @auto_routed_types and Keyword.get(el.opts, :handle_keys, true) do
              Map.put(widgets, focus_id, el)
            else
              widgets
            end

          {ids, widgets}
      end

    Enum.reduce(el.children, {ids, widgets}, &collect_ids_and_widgets/2)
  end

  defp collect_traps(%Element{} = el) do
    here =
      if Keyword.get(el.opts, :focus_trap) == true do
        [collect_focus_ids_only(el)]
      else
        []
      end

    here ++ Enum.flat_map(el.children, &collect_traps/1)
  end

  defp collect_focus_ids_only(%Element{} = el) do
    here =
      case Keyword.get(el.opts, :focusable) do
        nil -> []
        id -> [id]
      end

    here ++ Enum.flat_map(el.children, &collect_focus_ids_only/1)
  end
end
