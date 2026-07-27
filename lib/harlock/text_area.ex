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
  | `↑` / `↓` | move one line, keeping the column where possible |
  | `Home` / `End` | start / end of the current line |
  | `Ctrl-Home` / `Ctrl-End` | start / end of the whole value |

  Vertical motion clamps the column to the target line's length. There is no
  goal-column memory, so moving down through a short line and on to a long one
  leaves the cursor at the short line's width rather than restoring the
  original column.
  """

  alias Harlock.TextBuffer

  @type cursor :: non_neg_integer()
  @type position :: {non_neg_integer(), non_neg_integer()}

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

  @doc "Move one line up, clamping the column. No-op on the first line."
  @spec move_up(String.t(), cursor()) :: cursor()
  def move_up(value, cursor) when is_binary(value) do
    case position(value, cursor) do
      {0, _column} -> cursor
      {line, column} -> cursor_at(value, line - 1, column)
    end
  end

  @doc "Move one line down, clamping the column. No-op on the last line."
  @spec move_down(String.t(), cursor()) :: cursor()
  def move_down(value, cursor) when is_binary(value) do
    {line, column} = position(value, cursor)

    if line + 1 >= line_count(value) do
      cursor
    else
      cursor_at(value, line + 1, column)
    end
  end

  @doc "Cursor at the start of the current line."
  @spec line_home(String.t(), cursor()) :: cursor()
  def line_home(value, cursor) when is_binary(value) do
    {line, _column} = position(value, cursor)
    cursor_at(value, line, 0)
  end

  @doc "Cursor at the end of the current line."
  @spec line_end(String.t(), cursor()) :: cursor()
  def line_end(value, cursor) when is_binary(value) do
    {line, _column} = position(value, cursor)
    cursor_at(value, line, line_length(value, line))
  end

  defp line_length(value, line), do: value |> lines() |> Enum.at(line) |> String.length()

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
  @spec scroll_to_reveal(integer(), String.t(), cursor(), integer()) :: non_neg_integer()
  def scroll_to_reveal(scroll, value, cursor, height) when is_binary(value) and height > 0 do
    {line, _column} = position(value, cursor)
    scroll = max(scroll, 0)

    cond do
      line < scroll -> line
      line >= scroll + height -> line - height + 1
      true -> scroll
    end
  end

  def scroll_to_reveal(scroll, _value, _cursor, _height), do: max(scroll, 0)

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
    case apply_key(event, value, cursor, []) do
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
  def apply_key({:key, :enter, _mods}, value, cursor, ring) do
    {v, c} = insert_newline(value, cursor)
    {:edit, v, c, ring}
  end

  def apply_key({:key, :up, _mods}, value, cursor, ring),
    do: {:edit, value, move_up(value, cursor), ring}

  def apply_key({:key, :down, _mods}, value, cursor, ring),
    do: {:edit, value, move_down(value, cursor), ring}

  # Home / End are line-relative here; ctrl jumps to the ends of the value.
  def apply_key({:key, :home, mods}, value, cursor, ring) do
    if :ctrl in mods do
      {:edit, value, 0, ring}
    else
      {:edit, value, line_home(value, cursor), ring}
    end
  end

  def apply_key({:key, :end, mods}, value, cursor, ring) do
    if :ctrl in mods do
      {:edit, value, String.length(value), ring}
    else
      {:edit, value, line_end(value, cursor), ring}
    end
  end

  # Kills are line-relative here. Delegating these to TextBuffer would kill to
  # the end (or start) of the whole value, which is right for a single-line
  # input and wrong for a textarea.
  def apply_key({:key, {:char, ?k}, [:ctrl]}, value, cursor, ring) do
    eol = line_end(value, cursor)

    # At end-of-line, kill the newline and join — matching emacs kill-line.
    to = if eol == cursor and cursor < String.length(value), do: cursor + 1, else: eol

    kill(value, cursor, to, cursor, ring)
  end

  def apply_key({:key, {:char, ?u}, [:ctrl]}, value, cursor, ring) do
    bol = line_home(value, cursor)
    kill(value, bol, cursor, bol, ring)
  end

  # Everything else — printable input, backspace, delete, left/right, word
  # motions, word kills, yank — is single-line behaviour that works unchanged
  # on a flat cursor.
  def apply_key(event, value, cursor, ring) do
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
