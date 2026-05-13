defmodule Harlock.App.Runtime do
  @moduledoc false
  # The TEA loop. Owns the model; receives input events from Reader; renders
  # synchronously after any event or subscription message that produces a
  # model change. No periodic polling — the only wakeups are real work.
  #
  # When the user's update/2 returns :quit (or {:quit, _cmd}), the runtime
  # signals the caller via `{:harlock_done, reason}` and exits :normal. The
  # supervisor's rest_for_one strategy + Runtime's :temporary restart mean
  # the runtime can exit without triggering a restart cascade — Writer and
  # Reader stay up just long enough for the supervisor's shutdown sequence
  # (and the Keeper's terminate/2) to restore the terminal.

  use GenServer
  require Logger

  alias Harlock.Cmd
  alias Harlock.Element.Focusables
  alias Harlock.Element.Renderer
  alias Harlock.Focus
  alias Harlock.Render.Diff
  alias Harlock.Sub
  alias Harlock.Terminal.Keeper
  alias Harlock.Terminal.Reader
  alias Harlock.Terminal.Writer
  alias Harlock.Theme

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    app = Keyword.fetch!(opts, :app)
    writer = Keyword.fetch!(opts, :writer)
    reader = Keyword.fetch!(opts, :reader)
    task_sup = Keyword.fetch!(opts, :task_sup)
    theme = Keyword.get(opts, :theme, Theme.default())
    caller = Keyword.get(opts, :caller)

    Theme.__set__(theme)

    try do
      {rows, cols} = detect_size(opts)
      {model, init_cmd} = init_app(app, Keyword.get(opts, :init_arg))
      :ok = Reader.subscribe(reader, self())

      state = %{
        app: app,
        model: model,
        writer: writer,
        reader: reader,
        task_sup: task_sup,
        theme: theme,
        caller: caller,
        prev_frame: nil,
        dirty: true,
        rows: rows,
        cols: cols,
        focused: nil,
        focusables: [],
        traps: [],
        focus_stack: [],
        subs: %{},
        pending_cmd: init_cmd
      }

      {:ok, state, {:continue, :start}}
    after
      Theme.__clear__()
    end
  end

  @impl true
  def handle_continue(:start, state) do
    state = render(state)
    Cmd.dispatch(state.pending_cmd, self(), state.task_sup)
    {:noreply, %{state | pending_cmd: nil}}
  end

  @impl true
  def handle_info({:harlock_event, event}, state) do
    case maybe_handle_focus(event, state) do
      {:handled, state} -> {:noreply, render(state)}
      :pass -> apply_update(state, event)
    end
  end

  def handle_info({:harlock_resize, rows, cols}, state) do
    # prev_frame is discarded because diffing against a buffer of different
    # dimensions is meaningless — force a full redraw at the new size.
    new_state = %{state | rows: rows, cols: cols, prev_frame: nil, dirty: true}
    {:noreply, render(new_state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp init_app(app, init_arg) do
    case app.init(init_arg) do
      {model, cmd} -> {model, cmd}
      model -> {model, Cmd.none()}
    end
  end

  defp apply_update(state, event) do
    Focus.__set__(state.focused)
    Theme.__set__(state.theme)

    try do
      case state.app.update(event, state.model) do
        :quit ->
          notify_done(state, :normal)
          {:stop, :normal, state}

        {:quit, cmd} ->
          Cmd.dispatch(cmd, self(), state.task_sup)
          notify_done(state, :normal)
          {:stop, :normal, state}

        {model, cmd} ->
          new_state = render(%{state | model: model, dirty: true})
          Cmd.dispatch(cmd, self(), new_state.task_sup)
          {:noreply, new_state}

        model ->
          {:noreply, render(%{state | model: model, dirty: true})}
      end
    after
      Theme.__clear__()
      Focus.__clear__()
    end
  end

  defp maybe_handle_focus({:key, :tab, []}, state) do
    case focus_next(state) do
      ^state -> :pass
      new_state -> {:handled, %{new_state | dirty: true}}
    end
  end

  defp maybe_handle_focus({:key, :tab, [:shift]}, state) do
    case focus_prev(state) do
      ^state -> :pass
      new_state -> {:handled, %{new_state | dirty: true}}
    end
  end

  defp maybe_handle_focus(_event, _state), do: :pass

  defp focus_next(state) do
    case active_ids(state) do
      [] -> state
      ids -> %{state | focused: cycle(ids, state.focused, 1)}
    end
  end

  defp focus_prev(state) do
    case active_ids(state) do
      [] -> state
      ids -> %{state | focused: cycle(ids, state.focused, -1)}
    end
  end

  defp active_ids(%{focusables: focusables, traps: []}), do: focusables

  defp active_ids(%{focusables: focusables, traps: traps, focused: focused}) do
    # Innermost trap that contains the current focus wins. Falls back to the
    # last (deepest) trap, then to global focusables.
    Enum.find(Enum.reverse(traps), &(focused in &1)) ||
      List.last(traps) ||
      focusables
  end

  defp cycle(ids, current, direction) do
    case Enum.find_index(ids, &(&1 == current)) do
      nil ->
        # Current focus is no longer in the list (or never was). Start from
        # the beginning (forward) or end (backward).
        if direction == 1, do: List.first(ids), else: List.last(ids)

      idx ->
        n = length(ids)
        Enum.at(ids, rem(idx + direction + n, n))
    end
  end

  defp render(%{dirty: false} = state), do: state

  defp render(state) do
    Focus.__set__(state.focused)
    Theme.__set__(state.theme)

    try do
      tree = state.app.view(state.model)
      {focusables, traps} = Focusables.collect(tree)
      state = update_focus_state(state, focusables, traps)
      state = update_subs(state)
      frame = Renderer.render(tree, state.rows, state.cols, state.focused)
      diff = Diff.diff(state.prev_frame, frame)
      Writer.write(state.writer, diff)

      %{state | prev_frame: frame, dirty: false}
    rescue
      e ->
        Logger.error("Harlock render crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
        notify_done(state, {:render_error, e})
        reraise e, __STACKTRACE__
    after
      Theme.__clear__()
      Focus.__clear__()
    end
  end

  defp update_subs(state) do
    desired =
      if function_exported?(state.app, :subs, 1) do
        state.app.subs(state.model) |> List.wrap()
      else
        []
      end

    desired_set = MapSet.new(desired)
    current_set = MapSet.new(Map.keys(state.subs))

    to_stop = MapSet.difference(current_set, desired_set)
    to_start = MapSet.difference(desired_set, current_set)

    subs =
      Enum.reduce(to_stop, state.subs, fn spec, acc ->
        case Map.fetch(acc, spec) do
          {:ok, pid} ->
            if Process.alive?(pid) do
              Process.unlink(pid)
              Process.exit(pid, :shutdown)
            end

            Map.delete(acc, spec)

          :error ->
            acc
        end
      end)

    subs =
      Enum.reduce(to_start, subs, fn spec, acc ->
        pid = Sub.start(spec, self())
        Map.put(acc, spec, pid)
      end)

    %{state | subs: subs}
  end

  defp update_focus_state(state, focusables, traps) do
    cond do
      length(traps) > length(state.traps) ->
        # A new trap appeared (modal opened). Stash current focus and move
        # into the innermost new trap.
        new_focus = traps |> List.last() |> List.first() || state.focused

        %{
          state
          | focusables: focusables,
            traps: traps,
            focused: new_focus,
            focus_stack: [state.focused | state.focus_stack]
        }

      length(traps) < length(state.traps) ->
        # A trap disappeared (modal closed). Pop stashed focus.
        {restored, rest} = pop_stack(state.focus_stack, focusables)

        focused =
          if restored in active_focusable_set(focusables, traps),
            do: restored,
            else: List.first(active_focusable_set(focusables, traps))

        %{state | focusables: focusables, traps: traps, focused: focused, focus_stack: rest}

      true ->
        # No trap change. Clamp focused to active ids.
        active = active_focusable_set(focusables, traps)

        focused =
          if state.focused in active do
            state.focused
          else
            List.first(active)
          end

        %{state | focusables: focusables, traps: traps, focused: focused}
    end
  end

  defp active_focusable_set(focusables, []), do: focusables
  defp active_focusable_set(focusables, traps), do: List.last(traps) || focusables

  defp pop_stack([h | t], _focusables), do: {h, t}
  defp pop_stack([], focusables), do: {List.first(focusables), []}

  defp notify_done(%{caller: nil}, _reason), do: :ok

  defp notify_done(%{caller: caller}, reason) when is_pid(caller) do
    send(caller, {:harlock_done, reason})
  end

  defp detect_size(opts) do
    explicit_rows = Keyword.get(opts, :rows)
    explicit_cols = Keyword.get(opts, :cols)
    keeper = Keyword.get(opts, :keeper)

    {queried_rows, queried_cols} =
      if (explicit_rows && explicit_cols) || is_nil(keeper) do
        {nil, nil}
      else
        case Keeper.size(keeper) do
          {:ok, r, c} -> {r, c}
          _ -> {nil, nil}
        end
      end

    rows = explicit_rows || queried_rows || parse_int(System.get_env("LINES"), 24)
    cols = explicit_cols || queried_cols || parse_int(System.get_env("COLUMNS"), 80)
    {rows, cols}
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end
end
