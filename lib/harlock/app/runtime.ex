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
  alias Harlock.Element
  alias Harlock.Element.Focusables
  alias Harlock.Element.Renderer
  alias Harlock.Element.WidgetMetrics
  alias Harlock.Focus
  alias Harlock.Render.Diff
  alias Harlock.Sub
  alias Harlock.Terminal.Caps
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
    caps = Keyword.get(opts, :caps, Caps.detect())
    caller = Keyword.get(opts, :caller)

    Theme.__set__(theme)
    Caps.__set__(caps)

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
        caps: caps,
        caller: caller,
        prev_frame: nil,
        dirty: true,
        rows: rows,
        cols: cols,
        focused: nil,
        focusables: [],
        traps: [],
        focus_stack: [],
        routed_widgets: %{},
        widget_metrics: %{},
        subs: %{},
        pending_cmd: init_cmd
      }

      {:ok, state, {:continue, :start}}
    after
      Theme.__clear__()
      Caps.__clear__()
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
      {:handled, state} ->
        {:noreply, render(state)}

      :pass ->
        case maybe_route_widget(event, state) do
          {:routed, routed_event} -> apply_update(state, routed_event)
          :pass -> apply_update(state, event)
        end
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
    Caps.__set__(state.caps)
    meta = %{app: state.app, event: event, focused: state.focused}

    try do
      :telemetry.span([:harlock, :input, :dispatch], meta, fn ->
        result = dispatch_update(state, event)
        {result, meta}
      end)
    after
      Caps.__clear__()
      Theme.__clear__()
      Focus.__clear__()
    end
  end

  defp dispatch_update(state, event) do
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

  # R2: focus-aware key routing. If the focused element is an auto-routable
  # widget (viewport / tabs / text_input) and the key is one the widget
  # handles, translate the raw key into a widget-shaped message that the
  # app's update/2 receives instead. Apps still own the model write — they
  # just write one generic clause per widget kind instead of N per-key
  # clauses.
  #
  # Degrades to :pass on any unexpected shape (e.g. an app constructs a
  # viewport without :offset/:content_height) so misuse surfaces as a
  # render error in the user's code, not as a runtime crash on the
  # spine's handle_info path.
  defp maybe_route_widget({:key, _, _} = event, state) do
    with focus_id when not is_nil(focus_id) <- state.focused,
         {:ok, %Element{} = el} <- Map.fetch(state.routed_widgets, focus_id) do
      route_to_widget(el, event, focus_id, state)
    else
      _ -> :pass
    end
  end

  defp maybe_route_widget(_event, _state), do: :pass

  defp route_to_widget(%Element{type: :viewport} = el, {:key, key, _}, focus_id, state) do
    if key in [:up, :down, :page_up, :page_down, :home, :end] do
      with {:ok, offset} <- Keyword.fetch(el.opts, :offset),
           {:ok, content_height} <- Keyword.fetch(el.opts, :content_height) do
        # widget_metrics is populated during render_unsafe (the previous
        # frame). Safe to read here because every focus-changing path
        # (Tab handling, any update/2 returning a model) renders before the
        # next key event is processed — so the focused widget's metrics are
        # current. If you add a focus path that doesn't render, the fallback
        # to state.rows breaks page-step/:end clamping for short viewports.
        viewport_h = get_in(state.widget_metrics, [focus_id, :viewport_h]) || state.rows
        new_offset = Harlock.Viewport.apply_key(offset, content_height, viewport_h, key)

        if new_offset == offset do
          :pass
        else
          {:routed, {:harlock_scroll, focus_id, new_offset}}
        end
      else
        _ -> :pass
      end
    else
      :pass
    end
  end

  defp route_to_widget(%Element{type: :tabs} = el, event, focus_id, _state) do
    with {:ok, items} <- Keyword.fetch(el.opts, :items),
         {:ok, active} <- Keyword.fetch(el.opts, :active) do
      case Harlock.Tabs.apply_key(event, active, items) do
        {:select, ^active} -> :pass
        {:select, new_id} -> {:routed, {:harlock_select, focus_id, new_id}}
        :noop -> :pass
      end
    else
      _ -> :pass
    end
  end

  defp route_to_widget(%Element{type: :text_input} = el, event, focus_id, _state) do
    with {:ok, value} <- Keyword.fetch(el.opts, :value),
         {:ok, cursor} <- Keyword.fetch(el.opts, :cursor) do
      case Harlock.TextBuffer.apply_key(event, value, cursor) do
        {:edit, ^value, ^cursor} ->
          :pass

        {:edit, new_value, new_cursor} ->
          {:routed, {:harlock_edit, focus_id, {new_value, new_cursor}}}

        :submit ->
          {:routed, {:harlock_submit, focus_id}}

        :noop ->
          :pass
      end
    else
      _ -> :pass
    end
  end

  defp route_to_widget(_el, _event, _focus_id, _state), do: :pass

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
    Caps.__set__(state.caps)

    try do
      :telemetry.span(
        [:harlock, :frame, :render],
        %{app: state.app, dirty: state.dirty},
        fn ->
          new_state = render_unsafe(state)

          {new_state,
           %{
             app: state.app,
             dirty: state.dirty,
             rows: new_state.rows,
             cols: new_state.cols
           }}
        end
      )
    rescue
      e ->
        Logger.error("Harlock render crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
        notify_done(state, {:render_error, e})
        reraise e, __STACKTRACE__
    after
      Caps.__clear__()
      Theme.__clear__()
      Focus.__clear__()
    end
  end

  defp render_unsafe(state) do
    tree = state.app.view(state.model)
    {focusables, traps, routed_widgets} = Focusables.collect(tree)
    state = update_focus_state(state, focusables, traps)
    state = %{state | routed_widgets: routed_widgets}
    state = update_subs(state)

    WidgetMetrics.clear()
    frame = Renderer.render(tree, state.rows, state.cols, state.focused)
    widget_metrics = WidgetMetrics.consume()

    diff = Diff.diff(state.prev_frame, frame)
    Writer.write(state.writer, diff)

    %{state | prev_frame: frame, widget_metrics: widget_metrics, dirty: false}
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

  # Initial frame dimensions. Sources, in priority order:
  #
  #   1. Explicit `:rows` / `:cols` opts (the :test backend supplies these).
  #   2. `Keeper.size/1` via TIOCGWINSZ (the :terminal backend).
  #   3. 24×80 defaults — only reached when neither is available, i.e.
  #      something has gone wrong upstream.
  #
  # We don't fall back to LINES/COLUMNS env vars: subprocesses typically
  # don't inherit them, and the NIF path is reliable when there's a tty.
  defp detect_size(opts) do
    explicit_rows = Keyword.get(opts, :rows)
    explicit_cols = Keyword.get(opts, :cols)

    {queried_rows, queried_cols} =
      cond do
        explicit_rows && explicit_cols -> {nil, nil}
        keeper = Keyword.get(opts, :keeper) -> from_keeper(keeper)
        true -> {nil, nil}
      end

    {explicit_rows || queried_rows || 24, explicit_cols || queried_cols || 80}
  end

  defp from_keeper(keeper) do
    case Keeper.size(keeper) do
      {:ok, r, c} -> {r, c}
      _ -> {nil, nil}
    end
  end
end
