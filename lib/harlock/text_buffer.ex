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
  """

  alias Harlock.Width

  @type cursor :: non_neg_integer()
  @type input_event :: {:edit, String.t(), cursor()} | :submit | :noop

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
  def apply_key({:key, {:char, cp}, mods}, value, cursor)
      when is_integer(cp) and cp >= 0x20 and cp != 0x7F do
    if mods == [] or mods == [:shift] do
      {v, c} = insert(value, cursor, <<cp::utf8>>)
      {:edit, v, c}
    else
      :noop
    end
  end

  def apply_key({:key, :backspace, _mods}, value, cursor) do
    {v, c} = delete_backward(value, cursor)
    {:edit, v, c}
  end

  def apply_key({:key, :delete, _mods}, value, cursor) do
    {v, c} = delete_forward(value, cursor)
    {:edit, v, c}
  end

  def apply_key({:key, :left, _mods}, value, cursor) do
    {:edit, value, move_left(cursor)}
  end

  def apply_key({:key, :right, _mods}, value, cursor) do
    {:edit, value, move_right(value, cursor)}
  end

  def apply_key({:key, :home, _mods}, value, _cursor), do: {:edit, value, home()}

  def apply_key({:key, :end, _mods}, value, _cursor), do: {:edit, value, end_(value)}

  def apply_key({:key, :enter, _mods}, _value, _cursor), do: :submit

  def apply_key(_event, _value, _cursor), do: :noop
end
