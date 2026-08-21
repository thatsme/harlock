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
        goal_column: nil,
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
        # Routing can carry state back: a textarea's goal column has to survive
        # between keypresses, and it is interaction state the app never sees.
        case maybe_route_widget(event, state) do
          {:routed, routed_event, state} -> apply_update(state, routed_event)
          {:pass, state} -> apply_update(state, event)
        end
    end
  end

  def handle_info({:harlock_resize, rows, cols}, state) when rows > 0 and cols > 0 do
    # prev_frame is discarded because diffing against a buffer of different
    # dimensions is meaningless — force a full redraw at the new size.
    new_state = %{state | rows: rows, cols: cols, prev_frame: nil, dirty: true}
    {:noreply, render(new_state)}
  end

  # Same reasoning as detect_size/1: TIOCGWINSZ succeeds while reporting 0x0 on a
  # tty that was never told its geometry. Keeping the previous dimensions is
  # strictly better than resizing to a frame that cannot draw anything.
  def handle_info({:harlock_resize, _rows, _cols}, state), do: {:noreply, state}

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
  # widget (the types `Harlock.Element.Focusables` indexes) and the key is one
  # the widget handles, translate it into a widget-shaped message that the
  # app's update/2 receives instead. Apps still own the model write — they
  # just write one generic clause per widget kind instead of N per-key
  # clauses.
  #
  # Degrades to :pass on any unexpected shape (e.g. an app constructs a
  # viewport without :offset/:content_height) so misuse surfaces as a
  # render error in the user's code, not as a runtime crash on the
  # spine's handle_info path.
  # Every result carries state back, including `:pass`. A key can leave value
  # and cursor untouched while still changing interaction state — an `↑` on the
  # first row owns the goal column it could not move to — and that key must
  # still reach update/2, so `{:pass, state}` is a real outcome, not a no-op.
  defp maybe_route_widget({:key, _, _} = event, state) do
    with focus_id when not is_nil(focus_id) <- state.focused,
         {:ok, %Element{} = el} <- Map.fetch(state.routed_widgets, focus_id) do
      route_to_widget(el, event, focus_id, state)
    else
      _ -> {:pass, state}
    end
  end

  defp maybe_route_widget(_event, state), do: {:pass, state}

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
          {:pass, state}
        else
          {:routed, {:harlock_scroll, focus_id, new_offset}, state}
        end
      else
        _ -> {:pass, state}
      end
    else
      {:pass, state}
    end
  end

  defp route_to_widget(%Element{type: :tabs} = el, event, focus_id, state) do
    with {:ok, items} <- Keyword.fetch(el.opts, :items),
         {:ok, active} <- Keyword.fetch(el.opts, :active) do
      case Harlock.Tabs.apply_key(event, active, items) do
        {:select, ^active} -> {:pass, state}
        {:select, new_id} -> {:routed, {:harlock_select, focus_id, new_id}, state}
        :noop -> {:pass, state}
      end
    else
      _ -> {:pass, state}
    end
  end

  # A table routes whichever of its two movable things the rows source implies:
  # enumerable rows move :focused_row (the window auto-centres on it), a window
  # function moves :offset (there is no index to centre on). Both deliver an
  # existing message, so no new shape was added for this.
  defp route_to_widget(%Element{type: :table} = el, event, focus_id, state) do
    metrics = get_in(state.widget_metrics, [focus_id]) || %{}

    if metrics[:table_windowed?] do
      route_windowed_table(el, event, focus_id, state, metrics)
    else
      route_list_table(el, event, focus_id, state)
    end
  end

  # A menu splits movement from commitment: arrows deliver {:harlock_select, …}
  # as the highlight moves, Enter delivers {:harlock_submit, …}. Both tuples
  # already exist — tabs produces the first, text_input the second — so the
  # widget adds no new message shape.
  defp route_to_widget(%Element{type: :menu} = el, event, focus_id, state) do
    with {:ok, items} <- Keyword.fetch(el.opts, :items),
         {:ok, active} <- Keyword.fetch(el.opts, :active) do
      case Harlock.Menu.apply_key(event, active, items) do
        {:select, new_id} -> {:routed, {:harlock_select, focus_id, new_id}, state}
        :submit -> {:routed, {:harlock_submit, focus_id}, state}
        :noop -> {:pass, state}
      end
    else
      _ -> {:pass, state}
    end
  end

  # A select routes the same two tuples a menu does. :submit means "the action
  # key was pressed" — the app reads its own :open flag to know whether that
  # opens the list or commits the highlight, which is why no open/close message
  # shape had to be invented.
  defp route_to_widget(%Element{type: :select} = el, event, focus_id, state) do
    with {:ok, items} <- Keyword.fetch(el.opts, :items),
         {:ok, value} <- Keyword.fetch(el.opts, :value),
         {:ok, open?} <- Keyword.fetch(el.opts, :open) do
      highlight = Keyword.get(el.opts, :highlight, value)

      case Harlock.Select.apply_key(event, highlight, items, open?) do
        {:select, new_id} -> {:routed, {:harlock_select, focus_id, new_id}, state}
        :submit -> {:routed, {:harlock_submit, focus_id}, state}
        :noop -> {:pass, state}
      end
    else
      _ -> {:pass, state}
    end
  end

  # A tree is the one widget that needed a new routed tuple: expanding is not
  # selecting, and collapsing a node the app has not loaded yet has to be
  # distinguishable so the app can fire the Cmd that fetches it.
  defp route_to_widget(%Element{type: :tree} = el, event, focus_id, state) do
    with {:ok, nodes} <- Keyword.fetch(el.opts, :nodes),
         {:ok, expanded} <- Keyword.fetch(el.opts, :expanded),
         {:ok, focused_id} <- Keyword.fetch(el.opts, :focused) do
      case Harlock.Tree.apply_key(event, nodes, expanded, focused_id) do
        {:select, node_id} -> {:routed, {:harlock_select, focus_id, node_id}, state}
        {:toggle, node_id} -> {:routed, {:harlock_toggle, focus_id, node_id}, state}
        :submit -> {:routed, {:harlock_submit, focus_id}, state}
        :noop -> {:pass, state}
      end
    else
      _ -> {:pass, state}
    end
  end

  # A textarea produces the same {:harlock_edit, id, {value, cursor}} message a
  # text_input does — both own a (value, cursor) pair, so the app writes one
  # clause either way. It never submits: Enter inserts a newline.
  defp route_to_widget(%Element{type: :textarea} = el, event, focus_id, state) do
    with {:ok, value} <- Keyword.fetch(el.opts, :value),
         {:ok, cursor} <- Keyword.fetch(el.opts, :cursor) do
      # Recorded by the renderer on the previous frame; nil when the element
      # isn't wrapping, which keeps vertical motion logical-line based. Same
      # freshness argument as viewport_h above.
      wrap_width = get_in(state.widget_metrics, [focus_id, :textarea_wrap_width])

      case Harlock.TextArea.apply_key(event, value, cursor, [], wrap_width, state.goal_column) do
        # Unchanged still records the goal — an ↑ on the first row moves nothing
        # but owns the column, which is what lets ↓↓↑↑ come back to it. The key
        # itself still falls through to update/2, as it did before routing
        # carried state.
        {:edit, ^value, ^cursor, _ring, goal} ->
          {:pass, %{state | goal_column: goal}}

        {:edit, new_value, new_cursor, _ring, goal} ->
          {:routed, {:harlock_edit, focus_id, {new_value, new_cursor}},
           %{state | goal_column: goal}}

        :noop ->
          {:pass, %{state | goal_column: nil}}
      end
    else
      _ -> {:pass, state}
    end
  end

  defp route_to_widget(%Element{type: :text_input} = el, event, focus_id, state) do
    with {:ok, value} <- Keyword.fetch(el.opts, :value),
         {:ok, cursor} <- Keyword.fetch(el.opts, :cursor) do
      case Harlock.TextBuffer.apply_key(event, value, cursor) do
        {:edit, ^value, ^cursor} ->
          {:pass, state}

        {:edit, new_value, new_cursor} ->
          {:routed, {:harlock_edit, focus_id, {new_value, new_cursor}}, state}

        :submit ->
          {:routed, {:harlock_submit, focus_id}, state}

        :noop ->
          {:pass, state}
      end
    else
      _ -> {:pass, state}
    end
  end

  defp route_to_widget(_el, _event, _focus_id, state), do: {:pass, state}

  defp route_windowed_table(el, event, focus_id, state, metrics) do
    offset = el.opts |> Keyword.get(:offset, 0) |> max(0)
    body_h = metrics[:table_body_h] || state.rows
    at_end? = Map.get(metrics, :table_at_end?, false)

    case Harlock.Table.scroll_key(event, offset, body_h, at_end?) do
      {:scroll, new_offset} -> {:routed, {:harlock_scroll, focus_id, new_offset}, state}
      :noop -> {:pass, state}
    end
  end

  defp route_list_table(el, event, focus_id, state) do
    with {:ok, rows} <- Keyword.fetch(el.opts, :rows),
         {:ok, row_id} <- Keyword.fetch(el.opts, :row_id) do
      ids = rows |> Enum.to_list() |> Enum.map(row_id)

      case Harlock.Table.select_key(event, ids, Keyword.get(el.opts, :focused_row)) do
        {:select, id} -> {:routed, {:harlock_select, focus_id, id}, state}
        :noop -> {:pass, state}
      end
    else
      _ -> {:pass, state}
    end
  end

  # Focus moves discard the goal column: it belongs to a run of vertical motion
  # in one widget, and leaking it into the next textarea would start that
  # widget's first ↑ aiming at a column the user never set there.
  defp focus_next(state) do
    case active_ids(state) do
      [] -> state
      ids -> %{state | focused: cycle(ids, state.focused, 1), goal_column: nil}
    end
  end

  defp focus_prev(state) do
    case active_ids(state) do
      [] -> state
      ids -> %{state | focused: cycle(ids, state.focused, -1), goal_column: nil}
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

  # A zero dimension means "the kernel has no idea", not "a zero-column
  # terminal" — serial consoles routinely report 0x0 because nothing ever told
  # the tty its geometry, and TIOCGWINSZ succeeds while saying so. Treat it as
  # absent so the 24x80 fallback applies: `0 || 24` is `0` in Elixir, so
  # passing it through renders a 0x0 frame, which draws nothing at all and looks
  # like a hang rather than a misconfiguration.
  defp from_keeper(keeper) do
    case Keeper.size(keeper) do
      {:ok, r, c} when r > 0 and c > 0 -> {r, c}
      _ -> {nil, nil}
    end
  end
end
