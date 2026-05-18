defmodule Harlock.Viewport do
  @moduledoc """
  Helpers for the `viewport` element.

  The viewport renders a child taller than its allocated region and
  blits a window starting at `offset`. The application owns the offset
  (same TEA discipline as `text_input`); this module gives you a pure
  function to translate scroll keys into a new offset.

  ## Example

      def init(_), do: %{items: build_items(500), offset: 0, viewport_h: 20}

      def update({:key, key, _mods}, m) do
        offset =
          Harlock.Viewport.apply_key(
            m.offset,
            length(m.items),
            m.viewport_h,
            key
          )

        %{m | offset: offset}
      end

      def view(m) do
        viewport(
          child: vbox(children: Enum.map(m.items, &text(content: &1))),
          offset: m.offset,
          content_height: length(m.items)
        )
      end

  `:up`/`:down` move one row, `:page_up`/`:page_down` move by
  `viewport_h - 1` (leaves one row of context like most pagers),
  `:home`/`:end` jump to the extremes. Any other key returns the
  offset unchanged.

  ## Auto-routing (v0.4)

  When a viewport element carries a `:focusable` id, the runtime
  routes the six scroll keys to `apply_key/4` automatically and
  delivers the result to `update/2` as
  `{:harlock_scroll, focus_id, new_offset}` — the app only has to
  write where the offset lives on the model:

      viewport(focusable: :log, offset: m.offset, content_height: ...)

      def update({:harlock_scroll, :log, new_offset}, m),
        do: %{m | offset: new_offset}

  Calling `apply_key/4` from `update/2` directly is still supported
  (and required for viewports without a `:focusable` id, or with
  `handle_keys: false`).
  """

  @type key ::
          :up
          | :down
          | :page_up
          | :page_down
          | :home
          | :end
          | term()

  @doc """
  Apply a scroll-key event to the current offset.

  `content_height` is the total height of the scrollable content;
  `viewport_h` is the visible height. The result is clamped to
  `0..max(0, content_height - viewport_h)`.
  """
  @spec apply_key(integer(), non_neg_integer(), non_neg_integer(), key()) :: non_neg_integer()
  def apply_key(offset, content_height, viewport_h, key) do
    max_offset = max(0, content_height - viewport_h)
    page_step = max(1, viewport_h - 1)

    new_offset =
      case key do
        :up -> offset - 1
        :down -> offset + 1
        :page_up -> offset - page_step
        :page_down -> offset + page_step
        :home -> 0
        :end -> max_offset
        _ -> offset
      end

    new_offset |> max(0) |> min(max_offset)
  end
end
