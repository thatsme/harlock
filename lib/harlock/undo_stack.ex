defmodule Harlock.UndoStack do
  @moduledoc """
  Bounded undo/redo history for a `(value, cursor)` pair, held by the app.

  ## Why the app holds it

  It cannot live inside `Harlock.TextBuffer` or `Harlock.TextArea`. The app model
  owns `:value` and is free to rewrite it without the widget seeing — loading a
  file, clearing a form, applying a `Cmd` result. A history kept inside the
  widget would drift out of sync with the truth and start restoring text the user
  never typed. So the stack is a plain value the app keeps in its model and feeds
  explicitly:

      def update({:harlock_edit, :body, {value, cursor}}, m) do
        %{m | body: value, cursor: cursor, undo: UndoStack.record(m.undo, {value, cursor})}
      end

      def update({:key, {:char, ?z}, [:ctrl]}, m) do
        case UndoStack.undo(m.undo) do
          {:ok, {value, cursor}, undo} -> %{m | body: value, cursor: cursor, undo: undo}
          :error -> m
        end
      end

  Because the app decides when to `record/2`, a programmatic rewrite can simply
  skip it — or call `reset/2` to make the new content the new baseline.

  ## Snapshots, not commands

  Each entry is a whole `{value, cursor}` pair. For buffers the size a terminal
  edits, copying the string is cheaper than the bookkeeping an inverse-command
  stack needs, and it cannot get out of step with the text.

  The ring is capped (default 100 committed entries); the oldest are dropped. An
  edit still in progress is held separately and adds at most one more step, so
  `depth/1` can read one above the limit while you are mid-word.

  ## Coalescing is contract, not implementation

  A run of insertions collapses into **one** undo step, so typing a word and
  pressing undo removes the word rather than the last letter. That run breaks
  on:

    * **a newline** — paragraphs are natural units, and one undo should not
      swallow several of them
    * **a cursor jump** — moving somewhere else ends the edit you were making
    * **a delete after an insert** — changing direction starts a new step

  These are guarantees, not tuning. Coalescing too eagerly is worse than having
  no undo at all: a user who types a paragraph, presses undo expecting to lose a
  word, and loses the paragraph has had work destroyed rather than merely not
  restored.
  """

  @default_limit 100

  defstruct past: [], future: [], last: nil, run: nil, limit: @default_limit

  @type snapshot :: {String.t(), non_neg_integer()}
  @type kind :: :insert | :delete | :newline | :motion

  @type t :: %__MODULE__{
          past: [snapshot()],
          future: [snapshot()],
          last: snapshot() | nil,
          run: {kind(), snapshot()} | nil,
          limit: pos_integer()
        }

  @doc """
  A new stack.

  Options: `:limit` (default #{@default_limit}) caps committed entries, and
  `:from` seeds the baseline so the first edit has something to undo to.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      limit: Keyword.get(opts, :limit, @default_limit),
      last: Keyword.get(opts, :from)
    }
  end

  @doc """
  Make `snapshot` the new baseline, discarding all history.

  For when the app replaces the content outright — opening a different file —
  where undoing back into the previous document would be wrong.
  """
  @spec reset(t(), snapshot()) :: t()
  def reset(%__MODULE__{} = stack, snapshot),
    do: %{stack | past: [], future: [], run: nil, last: snapshot}

  @doc """
  Record the state *after* an edit.

  Classifies the transition since the last recorded state and either extends the
  current run or closes it and opens a new one. Recording an unchanged state is a
  no-op, so it is safe to call on every message.
  """
  @spec record(t(), snapshot()) :: t()
  def record(%__MODULE__{last: nil} = stack, snapshot), do: %{stack | last: snapshot}

  def record(%__MODULE__{} = stack, snapshot) do
    case classify(stack.last, snapshot) do
      :none ->
        stack

      # Motion ends whatever edit was in progress but is not itself undoable —
      # restoring a cursor position while leaving the text alone would spend an
      # undo press on nothing the user thinks of as a change.
      :motion ->
        %{close_run(stack) | last: snapshot, run: nil}

      kind ->
        cond do
          is_nil(stack.run) ->
            %{stack | run: {kind, stack.last}, last: snapshot, future: []}

          coalesces?(stack.run, kind) ->
            %{stack | last: snapshot, future: []}

          true ->
            %{close_run(stack) | run: {kind, stack.last}, last: snapshot, future: []}
        end
    end
  end

  @doc """
  Step back one entry.

  Returns `{:ok, snapshot, stack}` with the state to restore, or `:error` when
  there is nothing left. An in-progress run is its own nearest target, so undo
  works mid-typing without waiting for the run to close.
  """
  @spec undo(t()) :: {:ok, snapshot(), t()} | :error
  def undo(%__MODULE__{run: {_kind, start}} = stack) do
    {:ok, start, %{stack | run: nil, future: [stack.last | stack.future], last: start}}
  end

  def undo(%__MODULE__{past: [previous | rest]} = stack) do
    {:ok, previous, %{stack | past: rest, future: [stack.last | stack.future], last: previous}}
  end

  def undo(%__MODULE__{past: []}), do: :error

  @doc """
  Step forward one entry, undoing an undo.

  Returns `:error` when there is nothing to redo. Any fresh edit clears the redo
  history — the branch it belonged to no longer exists.
  """
  @spec redo(t()) :: {:ok, snapshot(), t()} | :error
  def redo(%__MODULE__{future: [next | rest]} = stack) do
    stack = %{stack | future: rest, past: cap([stack.last | stack.past], stack.limit)}
    {:ok, next, %{stack | last: next, run: nil}}
  end

  def redo(%__MODULE__{future: []}), do: :error

  @doc "Whether `undo/1` would succeed."
  @spec can_undo?(t()) :: boolean()
  def can_undo?(%__MODULE__{run: nil, past: []}), do: false
  def can_undo?(%__MODULE__{}), do: true

  @doc "Whether `redo/1` would succeed."
  @spec can_redo?(t()) :: boolean()
  def can_redo?(%__MODULE__{future: []}), do: false
  def can_redo?(%__MODULE__{}), do: true

  @doc """
  Number of undo steps available, counting an in-progress run as one.

  Intended for status lines and tests rather than control flow.
  """
  @spec depth(t()) :: non_neg_integer()
  def depth(%__MODULE__{} = stack), do: length(stack.past) + if(stack.run, do: 1, else: 0)

  # -- internals -------------------------------------------------------------

  defp close_run(%__MODULE__{run: nil} = stack), do: stack

  defp close_run(%__MODULE__{run: {_kind, start}} = stack),
    do: %{stack | past: cap([start | stack.past], stack.limit)}

  defp coalesces?({:insert, _start}, :insert), do: true
  defp coalesces?({:delete, _start}, :delete), do: true
  defp coalesces?(_run, _kind), do: false

  defp classify({value, cursor}, {value, cursor}), do: :none
  defp classify({value, _old}, {value, _new}), do: :motion

  defp classify({old_value, _old_cursor}, {new_value, _new_cursor}) do
    cond do
      newlines(new_value) > newlines(old_value) -> :newline
      String.length(new_value) > String.length(old_value) -> :insert
      true -> :delete
    end
  end

  defp newlines(value), do: value |> String.graphemes() |> Enum.count(&(&1 == "\n"))

  defp cap(list, limit), do: Enum.take(list, limit)
end
