# Run with:
#   ./scripts/run.sh notes
#
# Or from iex:
#   iex -S mix
#   iex> c "examples/notes.exs"
#   iex> Harlock.run(Notes)
#
# A one-widget note editor, kept deliberately small to show how little an app
# has to do to get a full multi-line editor:
#
#   * One update/2 clause handles every edit — the runtime routes keys to the
#     focused textarea and delivers {:harlock_edit, id, {value, cursor}}, the
#     same message a text_input produces.
#   * Vertical motion keeps its goal column across a run of arrows, so moving
#     down through a short line and back returns to the column you started in.
#     That is runtime-held state; the app never sees it.
#   * Word motions and kills (Alt-B / Alt-F, Ctrl-W, Alt-Backspace, Ctrl-K,
#     Ctrl-U, Ctrl-Y) come from Harlock.TextBuffer, shared with text_input.

defmodule Notes do
  use Harlock.App

  alias Harlock.{TextArea, TextBuffer}

  @placeholder "Type a note. F2 toggles wrapping, Esc quits."

  def init(_), do: %{body: "", cursor: 0, wrap: true}

  # Every keystroke the textarea handles arrives here, already applied to a
  # (value, cursor) pair. There is no per-key dispatch to write.
  def update({:harlock_edit, :body, {value, cursor}}, m),
    do: %{m | body: value, cursor: cursor}

  def update({:key, {:f, 2}, []}, m), do: %{m | wrap: not m.wrap}

  # Bracketed paste bypasses key routing, so the app owns what lands in the
  # buffer. Tabs are zero-width in a cell grid — every index after one would
  # render a column short of where it maps — so expand them on the way in.
  def update({:paste, text}, m) do
    {value, cursor} = TextBuffer.insert(m.body, m.cursor, TextArea.expand_tabs(text))
    %{m | body: value, cursor: cursor}
  end

  def update({:key, :escape, []}, _), do: :quit
  def update(_event, m), do: m

  def view(m) do
    {line, column} = TextArea.position(m.body, m.cursor)

    box(
      title: "Notes",
      title_align: :center,
      border: :rounded,
      border_style: [fg: :cyan],
      padding: {1, 2},
      child:
        vbox(
          constraints: [fill: 1, length: 1, length: 1],
          children: [
            # :scroll is left at its default. The renderer already adjusts it by
            # the minimum needed to keep the cursor visible, so an app that does
            # not track scrolling still gets a usable caret.
            textarea(
              value: m.body,
              cursor: m.cursor,
              wrap: m.wrap,
              focusable: :body,
              placeholder: @placeholder,
              placeholder_style: [dim: true]
            ),
            text(
              "line #{line + 1}, col #{column + 1}   " <>
                "#{TextArea.line_count(m.body)} lines   " <>
                "wrap #{if m.wrap, do: "on", else: "off"}",
              style: [fg: :cyan]
            ),
            text(
              "[F2] wrap  [Alt-B/F] word  [Ctrl-W/K/U] kill  [Ctrl-Y] yank  [Esc] quit",
              style: [dim: true]
            )
          ]
        )
    )
  end
end

# If running via `mix run examples/notes.exs` (rather than loading via iex),
# kick off the app immediately.
case System.argv() do
  ["--run"] -> Harlock.run(Notes)
  _ -> :ok
end
