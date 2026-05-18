defmodule Harlock.Element.WidgetIndex do
  @moduledoc false
  # Walks the element tree and returns a map from focus_id to the
  # focusable element for the subset of element types that opt in to
  # R2 auto-routing (currently :viewport). Used by the runtime to look
  # up the focused widget at key-dispatch time without re-walking the
  # tree on every keypress.
  #
  # Elements opt out of auto-routing with `handle_keys: false` in opts
  # (default is `true`).

  alias Harlock.Element

  @auto_routed_types [:viewport]

  @spec collect(Element.t()) :: %{any() => Element.t()}
  def collect(%Element{} = root), do: do_collect(root, %{})

  defp do_collect(%Element{} = el, acc) do
    acc =
      case Keyword.get(el.opts, :focusable) do
        nil ->
          acc

        id ->
          if el.type in @auto_routed_types and Keyword.get(el.opts, :handle_keys, true) do
            Map.put(acc, id, el)
          else
            acc
          end
      end

    Enum.reduce(el.children, acc, &do_collect/2)
  end
end
