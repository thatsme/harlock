defmodule Harlock.TextArea do
  @moduledoc """
  Pure helpers for editing a multi-line `(value, cursor)` pair.

  The value is an ordinary binary whose lines are separated by `\\n`, and the
  cursor is a flat grapheme index into it — the same representation
  `Harlock.TextBuffer` uses for a single line. Keeping the cursor flat rather
  than a `{row, column}` pair means cross-line motion falls out for free:
  moving left from the start of a line lands on the newline that ends the
  previous one, and deleting there joins the two lines. It also lets the
  runtime deliver textarea edits through the same
  `{:harlock_edit, id, {value, cursor}}` message a `text_input` uses.

  Horizontal editing — insert, delete, word motion, kills, yank — is
  delegated to `Harlock.TextBuffer`, so both widgets share one implementation
  and one set of key bindings. This module adds only what multi-line editing
  needs: vertical motion, line-relative Home / End, and Enter inserting a
  newline instead of submitting.

  ## Key bindings

  Everything `Harlock.TextBuffer` understands, plus:

  | Key | Action |
  | --- | --- |
  | `Enter` | insert a newline (never submits) |
  | `↑` / `↓` | move one display row, keeping the column where possible |
  | `Home` / `End` | start / end of the current display row |
  | `Ctrl-Home` / `Ctrl-End` | start / end of the whole value |

  ## Wrapping

  Pass a width to `apply_key/5` (or set `wrap: true` on the element, which
  makes the runtime pass the rendered width for you) and long lines break
  across display rows. Motion then follows those rows: `↓` inside a wrapped
  paragraph moves to the next visual row rather than past the whole paragraph.
  Without a width every "display row" is a logical line, so one code path
  serves both.

  Kills stay logical-line relative even when wrapping — `Ctrl-k` kills to the
  end of the line, not to the next wrap boundary, because that boundary isn't
  in the text.

  Columns are counted in display cells rather than graphemes throughout, so
  vertical motion through CJK text lands where it looks like it should, and
  wrapping breaks where the text actually reaches the edge.

  Vertical motion clamps the column to the target row's width. There is no
  goal-column memory, so moving down through a short row and on to a long one
  leaves the cursor at the short row's width rather than restoring the
  original column.
  """

  alias Harlock.TextBuffer
  alias Harlock.Width

  @type cursor :: non_neg_integer()
  @type position :: {non_neg_integer(), non_neg_integer()}

  @typedoc """
  A wrapped display row: the flat cursor index where the row begins, and the
  text on it. Segments concatenate back to the original value exactly, so a
  flat cursor maps onto them without loss.
  """
  @type visual_row :: {cursor(), String.t()}

  @typedoc """
  Width to wrap at, or `nil` for no wrapping. `nil` makes every motion
  logical-line based; a positive integer makes it display-row based.
  """
  @type wrap_width :: pos_integer() | nil

  @doc "Split the value into its lines. A trailing newline yields a final empty line."
  @spec lines(String.t()) :: [String.t()]
  def lines(value) when is_binary(value), do: String.split(value, "\n")

  @doc "Number of lines, counting a trailing empty line."
  @spec line_count(String.t()) :: pos_integer()
  def line_count(value) when is_binary(value), do: length(lines(value))

  @doc """
  Translate a flat cursor into `{line, column}`, both zero-based and measured
  in graphemes. Out-of-range cursors clamp to the end of the value.
  """
  @spec position(String.t(), cursor()) :: position()
  def position(value, cursor) when is_binary(value) do
    walk_position(lines(value), max(cursor, 0), 0)
  end

  defp walk_position([line], cursor, index), do: {index, min(cursor, String.length(line))}

  defp walk_position([line | rest], cursor, index) do
    len = String.length(line)

    if cursor <= len do
      {index, cursor}
    else
      # +1 for the newline that terminated this line.
      walk_position(rest, cursor - len - 1, index + 1)
    end
  end

  @doc """
  Translate a `{line, column}` pair back into a flat cursor. Both coordinates
  clamp into range, so callers can pass an over-long column and get the end of
  the line.
  """
  @spec cursor_at(String.t(), integer(), integer()) :: cursor()
  def cursor_at(value, line, column) when is_binary(value) do
    ls = lines(value)
    line = line |> max(0) |> min(length(ls) - 1)
    column = column |> max(0) |> min(String.length(Enum.at(ls, line)))

    offset =
      ls
      |> Enum.take(line)
      |> Enum.reduce(0, fn l, acc -> acc + String.length(l) + 1 end)

    offset + column
  end

  @doc """
  Move one display row up, preserving the display column. No-op on the first
  row.

  With a `width` the row is a wrapped segment; without one it is a logical
  line. Either way the column is preserved in display cells rather than
  graphemes, so moving up a column of CJK text lands where it looks like it
  should.
  """
  @spec move_up(String.t(), cursor(), wrap_width()) :: cursor()
  def move_up(value, cursor, width \\ nil) when is_binary(value) do
    case visual_position(value, cursor, width) do
      {0, _column} -> cursor
      {row, column} -> visual_cursor_at(value, row - 1, column, width)
    end
  end

  @doc "Move one display row down, preserving the display column. No-op on the last row."
  @spec move_down(String.t(), cursor(), wrap_width()) :: cursor()
  def move_down(value, cursor, width \\ nil) when is_binary(value) do
    {row, column} = visual_position(value, cursor, width)

    if row + 1 >= length(visual_rows(value, width)) do
      cursor
    else
      visual_cursor_at(value, row + 1, column, width)
    end
  end

  @doc "Cursor at the start of the current display row."
  @spec line_home(String.t(), cursor(), wrap_width()) :: cursor()
  def line_home(value, cursor, width \\ nil) when is_binary(value) do
    {row, _column} = visual_position(value, cursor, width)
    {start, _text} = value |> visual_rows(width) |> Enum.at(row)
    start
  end

  @doc "Cursor at the end of the current display row."
  @spec line_end(String.t(), cursor(), wrap_width()) :: cursor()
  def line_end(value, cursor, width \\ nil) when is_binary(value) do
    {row, _column} = visual_position(value, cursor, width)
    {start, text} = value |> visual_rows(width) |> Enum.at(row)
    start + String.length(text)
  end

  # -- Word wrapping ---------------------------------------------------------

  @doc """
  Break one logical line into display rows no wider than `width` columns.

  Breaks at the last space that fits, keeping that space on the preceding row
  so the rows concatenate back to the input exactly — that property is what
  lets a flat cursor index map onto wrapped rows without a separate
  translation table. A word longer than `width` is broken mid-word rather than
  overflowing.

  Width is measured in display columns via `Harlock.Width`, so a CJK grapheme
  costs two. A `width` too small to fit even one grapheme still consumes one
  per row rather than looping forever; the renderer clips the overflow.
  """
  @spec wrap_line(String.t(), pos_integer()) :: [String.t()]
  def wrap_line(line, width) when is_binary(line) and width > 0 do
    case String.graphemes(line) do
      [] -> [""]
      graphemes -> wrap_graphemes(graphemes, width)
    end
  end

  defp wrap_graphemes([], _width), do: []

  defp wrap_graphemes(graphemes, width) do
    # Always take at least one grapheme so a width narrower than a wide
    # grapheme still makes progress.
    fitting = max(fit_count(graphemes, width), 1)
    {head, tail} = Enum.split(graphemes, fitting)

    {head, tail} =
      cond do
        tail == [] ->
          {head, tail}

        # The text that fits ends exactly on a word boundary, so take the
        # separating space onto this row too. It overflows by one column, but a
        # trailing space is invisible and the renderer clips it — and without
        # this the row would break at the *previous* space and waste a word's
        # worth of columns.
        hd(tail) == " " ->
          Enum.split(graphemes, fitting + 1)

        true ->
          case last_space_index(head) do
            nil -> {head, tail}
            i -> Enum.split(graphemes, i + 1)
          end
      end

    [IO.iodata_to_binary(head) | wrap_graphemes(tail, width)]
  end

  # How many leading graphemes fit within `width` display columns.
  defp fit_count(graphemes, width) do
    graphemes
    |> Enum.reduce_while({0, 0}, fn g, {count, used} ->
      case used + Width.width(g) do
        w when w > width -> {:halt, {count, used}}
        w -> {:cont, {count + 1, w}}
      end
    end)
    |> elem(0)
  end

  defp last_space_index(graphemes) do
    graphemes
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {" ", i}, _acc -> i
      _, acc -> acc
    end)
  end

  @doc """
  All display rows for a value, as `{flat_cursor_at_row_start, text}`.

  With `nil` width this is just the logical lines, so callers can use one code
  path whether or not wrapping is on.
  """
  @spec visual_rows(String.t(), wrap_width()) :: [visual_row()]
  def visual_rows(value, width) when is_binary(value) do
    {rows, _offset} =
      value
      |> lines()
      |> Enum.reduce({[], 0}, fn line, {acc, offset} ->
        segments = if width, do: wrap_line(line, width), else: [line]

        {acc, offset} =
          Enum.reduce(segments, {acc, offset}, fn segment, {a, o} ->
            {[{o, segment} | a], o + String.length(segment)}
          end)

        # +1 for the newline terminating this logical line.
        {acc, offset + 1}
      end)

    Enum.reverse(rows)
  end

  @doc """
  Translate a flat cursor into `{display_row, display_column}`.

  The column is in display cells, not graphemes, so it can be handed straight
  to the renderer. A cursor sitting exactly on a wrap boundary reports the
  start of the following row, which is where a caret belongs after typing up
  to the edge.
  """
  @spec visual_position(String.t(), cursor(), wrap_width()) :: position()
  def visual_position(value, cursor, width) when is_binary(value) do
    rows = visual_rows(value, width)
    cursor = max(cursor, 0)

    index =
      rows
      |> Enum.with_index()
      |> Enum.reduce(0, fn {{start, _text}, i}, acc ->
        if start <= cursor, do: i, else: acc
      end)

    {start, text} = Enum.at(rows, index)
    {index, TextBuffer.cursor_column(text, cursor - start)}
  end

  @doc """
  Translate a `{display_row, display_column}` pair back into a flat cursor.
  Both coordinates clamp into range.
  """
  @spec visual_cursor_at(String.t(), integer(), integer(), wrap_width()) :: cursor()
  def visual_cursor_at(value, row, column, width) when is_binary(value) do
    rows = visual_rows(value, width)
    row = row |> max(0) |> min(length(rows) - 1)
    {start, text} = Enum.at(rows, row)

    start + index_at_column(text, max(column, 0))
  end

  # Largest grapheme index whose prefix is no wider than `target` columns.
  defp index_at_column(text, target) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, 0}, fn g, {index, used} ->
      case used + Width.width(g) do
        w when w > target -> {:halt, {index, used}}
        w -> {:cont, {index + 1, w}}
      end
    end)
    |> elem(0)
  end

  @doc """
  Adjust a scroll offset by the minimum needed to keep the cursor's line
  visible in a viewport `height` lines tall.

  The renderer applies this itself, so a textarea always draws its cursor even
  when the app pins `:scroll` to 0 — but an app that never tracks scroll keeps
  the cursor pinned to the last visible row once the value grows past one
  screen. Threading the result back onto the model gives the usual behaviour
  where the view only moves when the cursor would leave it:

      def update({:harlock_edit, :body, {v, c}}, m) do
        %{m | body: v, cursor: c, scroll: TextArea.scroll_to_reveal(m.scroll, v, c, m.body_h)}
      end
  """
  @spec scroll_to_reveal(integer(), String.t(), cursor(), integer(), wrap_width()) ::
          non_neg_integer()
  def scroll_to_reveal(scroll, value, cursor, height, width \\ nil)

  def scroll_to_reveal(scroll, value, cursor, height, width)
      when is_binary(value) and height > 0 do
    {row, _column} = visual_position(value, cursor, width)
    scroll = max(scroll, 0)

    cond do
      row < scroll -> row
      row >= scroll + height -> row - height + 1
      true -> scroll
    end
  end

  def scroll_to_reveal(scroll, _value, _cursor, _height, _width), do: max(scroll, 0)

  @doc "Insert a newline at the cursor."
  @spec insert_newline(String.t(), cursor()) :: {String.t(), cursor()}
  def insert_newline(value, cursor) when is_binary(value),
    do: TextBuffer.insert(value, cursor, "\n")

  @doc """
  Map a raw `{:key, key, mods}` event to an edit.

  Returns `{:edit, value, cursor}` or `:noop`. Unlike
  `Harlock.TextBuffer.apply_key/3` there is no `:submit` — Enter inserts a
  newline, so a textarea never submits on its own.
  """
  @spec apply_key({:key, any(), [atom()]}, String.t(), cursor()) ::
          {:edit, String.t(), cursor()} | :noop
  def apply_key(event, value, cursor) do
    case apply_key(event, value, cursor, [], nil) do
      {:edit, v, c, _ring} -> {:edit, v, c}
      other -> other
    end
  end

  @doc """
  As `apply_key/3`, but threads a kill ring so `Ctrl-y` works. See
  `Harlock.TextBuffer.apply_key/4`.
  """
  @spec apply_key({:key, any(), [atom()]}, String.t(), cursor(), TextBuffer.kill_ring()) ::
          {:edit, String.t(), cursor(), TextBuffer.kill_ring()} | :noop
  def apply_key(event, value, cursor, ring), do: apply_key(event, value, cursor, ring, nil)

  @doc """
  As `apply_key/4`, but wraps at `wrap_width` columns.

  With a width, `↑` / `↓` and Home / End act on display rows rather than
  logical lines — pressing `↓` inside a wrapped paragraph moves to the next
  visual row, not past the whole paragraph. `Ctrl-k` still kills to the end of
  the *logical* line: killing only to a wrap boundary would be surprising,
  since the boundary isn't in the text.

  The runtime passes the textarea's rendered width automatically when the
  element sets `wrap: true`.
  """
  @spec apply_key(
          {:key, any(), [atom()]},
          String.t(),
          cursor(),
          TextBuffer.kill_ring(),
          wrap_width()
        ) :: {:edit, String.t(), cursor(), TextBuffer.kill_ring()} | :noop
  def apply_key({:key, :enter, _mods}, value, cursor, ring, _width) do
    {v, c} = insert_newline(value, cursor)
    {:edit, v, c, ring}
  end

  def apply_key({:key, :up, _mods}, value, cursor, ring, width),
    do: {:edit, value, move_up(value, cursor, width), ring}

  def apply_key({:key, :down, _mods}, value, cursor, ring, width),
    do: {:edit, value, move_down(value, cursor, width), ring}

  # Home / End are display-row relative; ctrl jumps to the ends of the value.
  def apply_key({:key, :home, mods}, value, cursor, ring, width) do
    if :ctrl in mods do
      {:edit, value, 0, ring}
    else
      {:edit, value, line_home(value, cursor, width), ring}
    end
  end

  def apply_key({:key, :end, mods}, value, cursor, ring, width) do
    if :ctrl in mods do
      {:edit, value, String.length(value), ring}
    else
      {:edit, value, line_end(value, cursor, width), ring}
    end
  end

  # Kills are logical-line relative even when wrapping. Delegating them to
  # TextBuffer would kill to the end (or start) of the whole value, which is
  # right for a single-line input and wrong here; killing to a wrap boundary
  # would be wrong too, because that boundary is not in the text.
  def apply_key({:key, {:char, ?k}, [:ctrl]}, value, cursor, ring, _width) do
    eol = line_end(value, cursor, nil)

    # At end-of-line, kill the newline and join — matching emacs kill-line.
    to = if eol == cursor and cursor < String.length(value), do: cursor + 1, else: eol

    kill(value, cursor, to, cursor, ring)
  end

  def apply_key({:key, {:char, ?u}, [:ctrl]}, value, cursor, ring, _width) do
    bol = line_home(value, cursor, nil)
    kill(value, bol, cursor, bol, ring)
  end

  # Everything else — printable input, backspace, delete, left/right, word
  # motions, word kills, yank — is single-line behaviour that works unchanged
  # on a flat cursor.
  def apply_key(event, value, cursor, ring, _width) do
    TextBuffer.apply_key(event, value, cursor, ring)
  end

  # Remove graphemes in [from, to), leaving the cursor at new_cursor and
  # pushing what was removed onto the ring.
  defp kill(value, from, to, new_cursor, ring) do
    graphemes = String.graphemes(value)
    killed = graphemes |> Enum.slice(from, max(to - from, 0)) |> IO.iodata_to_binary()
    kept = Enum.take(graphemes, from) ++ Enum.drop(graphemes, to)

    {:edit, IO.iodata_to_binary(kept), new_cursor, TextBuffer.push_kill(ring, killed)}
  end
end
