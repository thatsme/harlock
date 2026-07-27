defmodule Harlock.TextBuffer do
  @moduledoc """
  Pure helpers for editing a `(value, cursor)` pair.

  The cursor is an integer index into `String.graphemes(value)` — `0` is
  before the first grapheme, `length(graphemes)` is after the last. This
  matches what users expect ("the cursor is between graphemes, not codepoints").
  Display column position is a separate concern, computed by `cursor_column/2`
  using `Harlock.Width`.

  These functions are owned by the app's model. The `text_input` element
  is a dumb renderer that reads `:value` and `:cursor` out of the model
  — no internal state. The app's `update/2` calls these helpers to react
  to key events.

  Typical usage:

      def update({:key, key, mods}, model) do
        case Harlock.Focus.current() do
          :search ->
            case TextBuffer.apply_key({:key, key, mods}, model.search, model.search_cursor) do
              {:edit, v, c} -> %{model | search: v, search_cursor: c}
              :submit -> trigger_search(model)
              :noop -> model
            end

          _ ->
            model
        end
      end

  ## Auto-routing (v0.4)

  When a `text_input` element is focused, the runtime routes its keys
  through `apply_key/3` automatically and delivers the result to
  `update/2` — the app's clauses get to the point:

      text_input(focusable: :search, value: m.search, cursor: m.cursor)

      def update({:harlock_edit, :search, {v, c}}, m),
        do: %{m | search: v, cursor: c}

      def update({:harlock_submit, :search}, m), do: trigger_search(m)

  Opt out with `handle_keys: false`; calling `apply_key/3` directly
  from `update/2` continues to work.

  ## Key bindings

  Beyond the arrow / Home / End / Backspace / Delete set, `apply_key/3`
  understands the readline-style editing keys. All of them arrive through the
  legacy parser — none require the kitty keyboard protocol:

  | Key | Action |
  | --- | --- |
  | `Alt-b` / `Alt-f` | move one word left / right |
  | `Ctrl-←` / `Ctrl-→` | move one word left / right |
  | `Ctrl-a` / `Ctrl-e` | move to start / end |
  | `Ctrl-w` | kill the word before the cursor |
  | `Alt-d` | kill the word after the cursor |
  | `Ctrl-k` / `Ctrl-u` | kill to end / to start |
  | `Ctrl-y` | yank the most recent kill |
  | `Ctrl-d` | delete forward |

  A word is a run of alphanumeric graphemes; everything else separates.

  > #### Focused inputs consume these keys {: .warning}
  >
  > When a `text_input` is focused and auto-routing is on, the runtime
  > consumes the keys above — an app that binds `Ctrl-k` globally will not see
  > it while the input has focus. Set `handle_keys: false` on the element to
  > keep them. Keys that don't change the value or cursor still fall through,
  > so an unmodified `Ctrl-a` on an empty input reaches `update/2` as usual.

  ## Kill ring

  `apply_key/3` threads an empty ring, so kills delete but `Ctrl-y` does
  nothing. Apps wanting yank hold the ring on their model and call
  `apply_key/4`. Undo is deliberately absent: the model owns `:value`, so it
  can be rewritten without this module seeing it, and a buffer-held history
  would silently desync.
  """

  alias Harlock.Width

  @type cursor :: non_neg_integer()
  @type input_event :: {:edit, String.t(), cursor()} | :submit | :noop

  @typedoc """
  Most-recent-first list of killed strings. Yank inserts the head.
  """
  @type kill_ring :: [String.t()]

  @typedoc """
  Result of `apply_key/4` — as `t:input_event/0` but threading the kill ring.
  """
  @type ring_event :: {:edit, String.t(), cursor(), kill_ring()} | :submit | :noop

  # Kills past this depth are dropped. Emacs defaults to 60; a text input is
  # not an editor, and an unbounded ring in a long-lived TUI session is a slow
  # leak.
  @kill_ring_limit 16

  @doc "Insert a string at the cursor. Returns the new value and cursor."
  @spec insert(String.t(), cursor(), String.t()) :: {String.t(), cursor()}
  def insert(value, cursor, str) when is_binary(value) and is_binary(str) do
    graphemes = String.graphemes(value)
    inserted = String.graphemes(str)
    {left, right} = Enum.split(graphemes, cursor)
    new_value = IO.iodata_to_binary(left ++ inserted ++ right)
    {new_value, cursor + length(inserted)}
  end

  @doc "Delete the grapheme before the cursor. No-op at position 0."
  @spec delete_backward(String.t(), cursor()) :: {String.t(), cursor()}
  def delete_backward(value, 0), do: {value, 0}

  def delete_backward(value, cursor) when is_binary(value) and cursor > 0 do
    graphemes = String.graphemes(value)
    {left, right} = Enum.split(graphemes, cursor)
    new_left = Enum.drop(left, -1)
    {IO.iodata_to_binary(new_left ++ right), cursor - 1}
  end

  @doc "Delete the grapheme after the cursor. No-op at end."
  @spec delete_forward(String.t(), cursor()) :: {String.t(), cursor()}
  def delete_forward(value, cursor) when is_binary(value) do
    graphemes = String.graphemes(value)

    if cursor >= length(graphemes) do
      {value, cursor}
    else
      {left, right} = Enum.split(graphemes, cursor)
      new_value = IO.iodata_to_binary(left ++ Enum.drop(right, 1))
      {new_value, cursor}
    end
  end

  @doc "Move cursor one grapheme left. Clamps at 0."
  @spec move_left(cursor()) :: cursor()
  def move_left(cursor) when cursor <= 0, do: 0
  def move_left(cursor), do: cursor - 1

  @doc "Move cursor one grapheme right. Clamps at the end."
  @spec move_right(String.t(), cursor()) :: cursor()
  def move_right(value, cursor) when is_binary(value) do
    min(cursor + 1, length(String.graphemes(value)))
  end

  @doc "Move cursor to the start."
  @spec home() :: cursor()
  def home, do: 0

  @doc "Move cursor to the end (one past the last grapheme)."
  @spec end_(String.t()) :: cursor()
  def end_(value) when is_binary(value), do: length(String.graphemes(value))

  # -- Word motions ----------------------------------------------------------
  #
  # Word boundaries follow the readline convention: a word is a run of
  # alphanumeric graphemes, and everything else is a separator. Motion skips
  # any separators adjacent to the cursor first, then traverses the word. A
  # multi-codepoint grapheme cluster that isn't wholly alphanumeric (an emoji
  # ZWJ sequence, say) counts as a separator — deliberate, since treating it
  # as a word constituent would make Alt-F skip past a run of emoji as if it
  # were a single word.

  defp word_char?(grapheme), do: String.match?(grapheme, ~r/^[[:alnum:]]+$/u)

  @doc """
  Move the cursor to the start of the previous word. Clamps at 0.
  """
  @spec move_word_left(String.t(), cursor()) :: cursor()
  def move_word_left(value, cursor) when is_binary(value) do
    graphemes = String.graphemes(value)

    cursor
    |> skip_left(graphemes, false)
    |> skip_left(graphemes, true)
  end

  @doc """
  Move the cursor to the end of the next word. Clamps at the end of the value.
  """
  @spec move_word_right(String.t(), cursor()) :: cursor()
  def move_word_right(value, cursor) when is_binary(value) do
    graphemes = String.graphemes(value)

    cursor
    |> skip_right(graphemes, false)
    |> skip_right(graphemes, true)
  end

  defp skip_left(i, graphemes, want_word?) do
    if i > 0 and word_char?(Enum.at(graphemes, i - 1)) == want_word? do
      skip_left(i - 1, graphemes, want_word?)
    else
      i
    end
  end

  defp skip_right(i, graphemes, want_word?) do
    if i < length(graphemes) and word_char?(Enum.at(graphemes, i)) == want_word? do
      skip_right(i + 1, graphemes, want_word?)
    else
      i
    end
  end

  # -- Kill operations -------------------------------------------------------
  #
  # Each returns `{value, cursor, killed}`. The killed text is returned rather
  # than stored so these stay pure — the caller decides whether it goes on a
  # kill ring, and `apply_key/3` simply discards it (making Ctrl-W / Ctrl-K /
  # Ctrl-U behave as plain deletes when no ring is being threaded).

  @doc """
  Delete from the start of the previous word up to the cursor.
  Returns `{value, cursor, killed}`.
  """
  @spec kill_word_backward(String.t(), cursor()) :: {String.t(), cursor(), String.t()}
  def kill_word_backward(value, cursor) when is_binary(value) do
    target = move_word_left(value, cursor)
    cut(value, target, cursor, target)
  end

  @doc """
  Delete from the cursor up to the end of the next word.
  Returns `{value, cursor, killed}`.
  """
  @spec kill_word_forward(String.t(), cursor()) :: {String.t(), cursor(), String.t()}
  def kill_word_forward(value, cursor) when is_binary(value) do
    target = move_word_right(value, cursor)
    cut(value, cursor, target, cursor)
  end

  @doc """
  Delete from the cursor to the end of the value. Returns `{value, cursor, killed}`.
  """
  @spec kill_to_end(String.t(), cursor()) :: {String.t(), cursor(), String.t()}
  def kill_to_end(value, cursor) when is_binary(value) do
    cut(value, cursor, length(String.graphemes(value)), cursor)
  end

  @doc """
  Delete from the start of the value to the cursor. Returns `{value, cursor, killed}`.
  """
  @spec kill_to_bol(String.t(), cursor()) :: {String.t(), cursor(), String.t()}
  def kill_to_bol(value, cursor) when is_binary(value) do
    cut(value, 0, cursor, 0)
  end

  # Remove graphemes in [from, to) and place the cursor at new_cursor.
  defp cut(value, from, to, new_cursor) do
    graphemes = String.graphemes(value)
    killed = graphemes |> Enum.slice(from, max(to - from, 0)) |> IO.iodata_to_binary()
    kept = Enum.take(graphemes, from) ++ Enum.drop(graphemes, to)
    {IO.iodata_to_binary(kept), new_cursor, killed}
  end

  @doc """
  Push killed text onto a ring.

  An empty kill is dropped rather than pushed, so a stray `Ctrl-k` at
  end-of-line doesn't shadow the previous kill, and the ring is capped so a
  long-lived session doesn't accumulate one indefinitely. Exposed so
  `Harlock.TextArea` can build line-relative kills on the same ring policy.
  """
  @spec push_kill(kill_ring(), String.t()) :: kill_ring()
  def push_kill(ring, ""), do: ring
  def push_kill(ring, text), do: Enum.take([text | ring], @kill_ring_limit)

  @doc """
  Insert the most recent kill at the cursor. An empty ring is a no-op.
  """
  @spec yank(String.t(), cursor(), kill_ring()) :: {String.t(), cursor()}
  def yank(value, cursor, []), do: {value, cursor}
  def yank(value, cursor, [most_recent | _]), do: insert(value, cursor, most_recent)

  @doc """
  Display column corresponding to a cursor index — the sum of display widths
  of all graphemes before the cursor. Useful for positioning the terminal
  cursor in the renderer.
  """
  @spec cursor_column(String.t(), cursor()) :: non_neg_integer()
  def cursor_column(value, cursor) when is_binary(value) do
    value
    |> String.graphemes()
    |> Enum.take(cursor)
    |> Enum.reduce(0, fn g, acc -> acc + Width.width(g) end)
  end

  @doc """
  Map a raw `{:key, key, mods}` event to an edit. Returns one of:

    * `{:edit, value, cursor}` — model should adopt the new pair
    * `:submit` — user pressed Enter; app handles submission
    * `:noop` — key isn't part of the text-input vocabulary, ignore
  """
  @spec apply_key({:key, any(), [atom()]}, String.t(), cursor()) :: input_event()
  def apply_key(event, value, cursor) do
    case apply_key(event, value, cursor, []) do
      {:edit, v, c, _ring} -> {:edit, v, c}
      other -> other
    end
  end

  @doc """
  As `apply_key/3`, but threads a kill ring so `Ctrl-Y` (yank) works.

  Returns `{:edit, value, cursor, kill_ring}` on an edit. Kill operations push
  onto the ring; yank reads its head. Apps that want full emacs editing hold
  the ring on their model alongside `:value` and `:cursor`:

      def update({:key, _, _} = ev, m) do
        case TextBuffer.apply_key(ev, m.value, m.cursor, m.ring) do
          {:edit, v, c, ring} -> %{m | value: v, cursor: c, ring: ring}
          :submit -> submit(m)
          :noop -> m
        end
      end

  The runtime's auto-routing (R2) calls `apply_key/3`, which threads an empty
  ring — so kills still delete, but yank is a no-op. Set `handle_keys: false`
  on the element and call this function directly to opt into the ring.
  """
  @spec apply_key({:key, any(), [atom()]}, String.t(), cursor(), kill_ring()) :: ring_event()

  # Word motions. These must precede the generic char clause below, which
  # matches any {:char, _} regardless of mods.
  def apply_key({:key, {:char, ?b}, [:alt]}, value, cursor, ring),
    do: {:edit, value, move_word_left(value, cursor), ring}

  def apply_key({:key, {:char, ?f}, [:alt]}, value, cursor, ring),
    do: {:edit, value, move_word_right(value, cursor), ring}

  # Emacs line motions.
  def apply_key({:key, {:char, ?a}, [:ctrl]}, value, _cursor, ring),
    do: {:edit, value, home(), ring}

  def apply_key({:key, {:char, ?e}, [:ctrl]}, value, _cursor, ring),
    do: {:edit, value, end_(value), ring}

  # Kills. Each pushes the removed text onto the ring.
  def apply_key({:key, {:char, ?w}, [:ctrl]}, value, cursor, ring),
    do: killed(kill_word_backward(value, cursor), ring)

  def apply_key({:key, {:char, ?d}, [:alt]}, value, cursor, ring),
    do: killed(kill_word_forward(value, cursor), ring)

  def apply_key({:key, {:char, ?k}, [:ctrl]}, value, cursor, ring),
    do: killed(kill_to_end(value, cursor), ring)

  def apply_key({:key, {:char, ?u}, [:ctrl]}, value, cursor, ring),
    do: killed(kill_to_bol(value, cursor), ring)

  def apply_key({:key, {:char, ?y}, [:ctrl]}, value, cursor, ring) do
    {v, c} = yank(value, cursor, ring)
    {:edit, v, c, ring}
  end

  # Emacs delete-forward, alongside the :delete key.
  def apply_key({:key, {:char, ?d}, [:ctrl]}, value, cursor, ring) do
    {v, c} = delete_forward(value, cursor)
    {:edit, v, c, ring}
  end

  def apply_key({:key, {:char, cp}, mods}, value, cursor, ring)
      when is_integer(cp) and cp >= 0x20 and cp != 0x7F do
    if mods == [] or mods == [:shift] do
      {v, c} = insert(value, cursor, <<cp::utf8>>)
      {:edit, v, c, ring}
    else
      :noop
    end
  end

  # Ctrl-modified arrows are word motions; unmodified arrows step one grapheme.
  def apply_key({:key, :left, mods}, value, cursor, ring) do
    if :ctrl in mods do
      {:edit, value, move_word_left(value, cursor), ring}
    else
      {:edit, value, move_left(cursor), ring}
    end
  end

  def apply_key({:key, :right, mods}, value, cursor, ring) do
    if :ctrl in mods do
      {:edit, value, move_word_right(value, cursor), ring}
    else
      {:edit, value, move_right(value, cursor), ring}
    end
  end

  def apply_key({:key, :backspace, _mods}, value, cursor, ring) do
    {v, c} = delete_backward(value, cursor)
    {:edit, v, c, ring}
  end

  def apply_key({:key, :delete, _mods}, value, cursor, ring) do
    {v, c} = delete_forward(value, cursor)
    {:edit, v, c, ring}
  end

  def apply_key({:key, :home, _mods}, value, _cursor, ring), do: {:edit, value, home(), ring}

  def apply_key({:key, :end, _mods}, value, _cursor, ring), do: {:edit, value, end_(value), ring}

  def apply_key({:key, :enter, _mods}, _value, _cursor, _ring), do: :submit

  def apply_key(_event, _value, _cursor, _ring), do: :noop

  defp killed({value, cursor, text}, ring), do: {:edit, value, cursor, push_kill(ring, text)}
end
