# Run with:
#   ./scripts/run.sh showcase
#
# or directly:
#   mix run examples/showcase.exs --run
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes.
#
# A five-tab tour of the widgets. Focused widgets have their keys routed
# by the runtime, so update/2 holds no per-key dispatch for them:
#
#   * tabs          — the tab bar; Left / Right while it has focus, or a click
#   * viewport      — a 200-line log with a scrollbar; the wheel scrolls it
#   * text_input    — 14 fields inside a viewport, kept in view as Tab moves
#   * progress, spinner, statusbar, keybar — driven by a Sub.interval
#   * button, checkbox — pause the progress bar, and choose whether it loops
#   * radio_group   — one choice among options, vertical or side by side
#   * list          — a list box that picks one, and a check list that picks
#                     several with Space or a click
#   * textarea      — multi-line notes, wrapped
#   * styled text   — the header, and each log line's level and service
#   * mouse         — clicks on tabs, fields and controls; the Keys tab shows
#                     the raw mouse events nothing else takes
#   * modified keys — Ctrl / Shift / Alt with arrows, shown in the Keys tab
#
# Tabs:
#
#   1. Logs    — Tab into the log, then arrows / PgUp / PgDn; [ and ] cycle alerts
#   2. Form    — Tab cycles fields; scroll-into-view keeps the focused one visible
#   3. Widgets — Space or the button pauses (unless the checkbox has focus, which
#                takes Space itself); the checkbox stops it looping
#   4. Keys    — the last 12 key and mouse events
#   5. Inputs  — an order form: radio groups, check list, list box, checkbox,
#                textarea, Save and Reset
#
# Shift-Left / Shift-Right and 1-5 switch tabs whenever the focused widget does
# not use those keys itself: a text field or the notes area types digits, and
# the tab bar and radio groups move on arrows. Quit: Ctrl-C from anywhere, or q
# while no text field or the notes area has focus.

defmodule ShowcaseApp do
  use Harlock.App

  alias Harlock.Focus

  @log_lines (for i <- 1..200 do
                level = Enum.at(~w(INFO  WARN  ERROR DEBUG), rem(i, 4))
                service = Enum.at(~w(api worker scheduler cache db), rem(i, 5))

                msg =
                  Enum.at(
                    [
                      "request handled in #{rem(i * 7, 250)}ms",
                      "queue depth #{rem(i, 50)}",
                      "cache miss key=k#{i}",
                      "rebalancing partition #{rem(i, 12)}",
                      "user #{1000 + i} authenticated",
                      "snapshot persisted (#{rem(i * 13, 1024)}KB)"
                    ],
                    rem(i, 6)
                  )

                {String.pad_leading(Integer.to_string(i), 3), level, service, msg}
              end)

  @form_fields ~w(
    first_name last_name email phone company role
    street city zip country website notes
    referrer tags
  )a

  def init(_) do
    %{
      tab: :logs,
      tick: 0,
      now: time_string(),
      keys: [],
      logs: %{offset: 0, focused_alert: 0, alert_rows: alert_rows()},
      form: %{
        offset: 0,
        values: Map.new(@form_fields, &{&1, ""}),
        cursors: Map.new(@form_fields, &{&1, 0})
      },
      widgets: %{progress: 0, working?: true, loop?: true},
      inputs: inputs_defaults()
    }
  end

  def subs(_model), do: [Harlock.Sub.interval(100, :tick)]

  # ----- update -----

  def update({:key, {:char, ?c}, [:ctrl]}, _model), do: :quit

  def update(:tick, model) do
    progress = advance(model.widgets)

    %{
      model
      | tick: model.tick + 1,
        now: time_string(),
        widgets: %{model.widgets | progress: progress}
    }
  end

  # Tab switching: 1-5 number keys (when not inside the Form tab where it
  # would be typed into a field), and Shift-Left / Shift-Right.
  def update({:key, {:char, c}, []}, model)
      when c in ?1..?5 and model.tab != :form do
    %{model | tab: tab_for_digit(c)}
  end

  def update({:key, :right, [:shift]}, model), do: %{model | tab: cycle_tab(model.tab, +1)}
  def update({:key, :left, [:shift]}, model), do: %{model | tab: cycle_tab(model.tab, -1)}

  # The focused tab bar routes Left / Right, and a click on a tab, here.
  def update({:harlock_select, :tabs, tab}, model), do: %{model | tab: tab}

  # 'q' quits only when no input is focused.
  def update({:key, {:char, ?q}, []}, model) do
    if input_focused?(model), do: model, else: :quit
  end

  # Keys tab: every other key and mouse event that reaches update/2, verbatim —
  # the tab-switching keys and q above keep their meaning. Routed keys and
  # clicks on focusable elements become widget messages instead, so what shows
  # here is what the app itself would have to handle.
  def update({tag, _, _} = ev, %{tab: :keys} = model)
      when tag in [:key, :key_repeat, :key_release],
      do: capture(model, ev)

  def update({:mouse, _, _, _, _, _} = ev, %{tab: :keys} = model), do: capture(model, ev)

  # Logs tab: scrolling is routed by the runtime via :logs_viewport. Tab is
  # used by the runtime for focus traversal, so alert cycling is on `[` / `]`.
  def update({:harlock_scroll, :logs_viewport, n}, model) do
    %{model | logs: %{model.logs | offset: n}}
  end

  def update({:key, {:char, ?]}, []}, %{tab: :logs} = model) do
    n = length(model.logs.alert_rows)
    next = rem(model.logs.focused_alert + 1, n)
    %{model | logs: %{model.logs | focused_alert: next}}
  end

  def update({:key, {:char, ?[}, []}, %{tab: :logs} = model) do
    n = length(model.logs.alert_rows)
    next = rem(model.logs.focused_alert - 1 + n, n)
    %{model | logs: %{model.logs | focused_alert: next}}
  end

  # Form tab: the runtime routes the focused field's edits to this clause.
  def update({:harlock_edit, {:form_field, field}, {v, c}}, model) do
    new_values = Map.put(model.form.values, field, v)
    new_cursors = Map.put(model.form.cursors, field, c)
    %{model | form: %{model.form | values: new_values, cursors: new_cursors}}
  end

  # Widgets tab: Space on the tab, or the button, pauses and resumes. A focused
  # button or checkbox takes Space itself — the button presses, the checkbox
  # toggles — so the raw-key clause only sees it when neither has focus.
  def update({:key, {:char, ?\s}, []}, %{tab: :widgets} = model), do: toggle_working(model)
  def update({:harlock_submit, :pause}, model), do: toggle_working(model)

  def update({:harlock_toggle, :loop, loop?}, model),
    do: %{model | widgets: %{model.widgets | loop?: loop?}}

  # Inputs tab: each control delivers its routed message, and each clause only
  # writes the value back. The check list sends a toggle for the app to flip in
  # its set.
  def update({:harlock_select, id, value}, model) when id in [:size, :delivery, :crust],
    do: put_input(model, id, value)

  def update({:harlock_select, :toppings, id}, model), do: put_input(model, :topping, id)

  def update({:harlock_toggle, :toppings, id}, model) do
    set = model.inputs.toppings

    put_input(
      model,
      :toppings,
      if(id in set, do: MapSet.delete(set, id), else: MapSet.put(set, id))
    )
  end

  def update({:harlock_toggle, :gift, gift?}, model), do: put_input(model, :gift, gift?)

  def update({:harlock_edit, :notes, {value, cursor}}, model),
    do: %{model | inputs: %{model.inputs | notes: value, notes_cursor: cursor}}

  def update({:harlock_submit, :save_order}, model),
    do: put_input(model, :saved, order_summary(model.inputs))

  def update({:harlock_submit, :reset_order}, model), do: %{model | inputs: inputs_defaults()}

  def update(_ev, model), do: model

  # ----- view -----

  def view(model) do
    vbox(
      constraints: [length: 1, length: 1, fill: 1, length: 1, length: 1],
      children: [
        header(model),
        tab_bar(model),
        body(model),
        status_row(model),
        key_row(model)
      ]
    )
  end

  defp header(_model) do
    hbox(
      constraints: [fill: 1, fill: 1],
      children: [
        text([{" Harlock ", bold: true, reverse: true, fg: :cyan}, {" Showcase", bold: true}]),
        text("viewport · tabs · widgets · keys · mouse ", align: :right, style: [dim: true])
      ]
    )
  end

  defp tab_bar(model) do
    tabs(
      focusable: :tabs,
      items: [
        {:logs, "1. Logs"},
        {:form, "2. Form"},
        {:widgets, "3. Widgets"},
        {:keys, "4. Keys"},
        {:inputs, "5. Inputs"}
      ],
      active: model.tab,
      separator: "  "
    )
  end

  defp body(model) do
    box(
      title: " #{tab_label(model.tab)} ",
      border: :rounded,
      border_style: %Style{fg: :bright_black},
      padding: 1,
      child: tab_body(model)
    )
  end

  defp tab_body(%{tab: :logs} = model), do: logs_body(model)
  defp tab_body(%{tab: :form} = model), do: form_body(model)
  defp tab_body(%{tab: :widgets} = model), do: widgets_body(model)
  defp tab_body(%{tab: :keys} = model), do: keys_body(model)
  defp tab_body(%{tab: :inputs} = model), do: inputs_body(model)

  # -- Logs tab --

  defp logs_body(model) do
    focused_row = Enum.at(model.logs.alert_rows, model.logs.focused_alert)

    child =
      vbox(
        constraints: Enum.map(@log_lines, fn _ -> {:length, 1} end),
        children:
          Enum.with_index(@log_lines, fn line, idx ->
            log_line(line, idx, idx == focused_row)
          end)
      )

    hbox(
      constraints: [fill: 1, length: 22],
      children: [
        viewport(
          focusable: :logs_viewport,
          child: child,
          offset: model.logs.offset,
          content_height: length(@log_lines),
          scrollbar: true
        ),
        logs_legend(model)
      ]
    )
  end

  # The alert row is highlighted whole; the others colour only their level and
  # service, which is what styled runs are for.
  defp log_line({n, level, service, msg}, _idx, true) do
    text("▶ #{n}  #{String.pad_trailing(level, 5)}  #{String.pad_trailing(service, 9)}  #{msg}",
      style: %Style{bold: true, fg: :yellow}
    )
  end

  defp log_line({n, level, service, msg}, _idx, false) do
    text([
      {"  #{n}  ", dim: true},
      {String.pad_trailing(level, 5), level_style(level)},
      "  ",
      {String.pad_trailing(service, 9), fg: :cyan},
      "  " <> msg
    ])
  end

  defp level_style("ERROR"), do: [fg: :red, bold: true]
  defp level_style("WARN"), do: [fg: :yellow]
  defp level_style("DEBUG"), do: [dim: true]
  defp level_style(_info), do: [fg: :green]

  defp logs_legend(model) do
    box(
      title: " legend ",
      border: :rounded,
      border_style: %Style{fg: :bright_black},
      padding: 1,
      child:
        vbox(
          constraints: [length: 1, length: 1, length: 1, length: 1, length: 1, fill: 1],
          children: [
            text("offset: #{model.logs.offset}", style: %Style{dim: true}),
            text("total: #{length(@log_lines)}", style: %Style{dim: true}),
            text("alert: #{model.logs.focused_alert + 1}/#{length(model.logs.alert_rows)}",
              style: %Style{fg: :yellow}
            ),
            spacer(),
            text("[ / ] cycle alert", style: %Style{dim: true})
          ]
        )
    )
  end

  # -- Form tab --

  defp form_body(model) do
    field_count = length(@form_fields)
    line_h = 2

    child =
      vbox(
        constraints: Enum.map(@form_fields, fn _ -> {:length, line_h} end),
        children: Enum.map(@form_fields, &form_field_row(&1, model))
      )

    viewport(
      child: child,
      offset: model.form.offset,
      content_height: field_count * line_h,
      scrollbar: true
    )
  end

  defp form_field_row(field, model) do
    hbox(
      constraints: [length: 14, fill: 1],
      children: [
        text(field_label(field) <> ":", style: %Style{bold: true}),
        text_input(
          value: model.form.values[field],
          cursor: model.form.cursors[field],
          placeholder: "(Tab to focus, type to edit)",
          focusable: {:form_field, field}
        )
      ]
    )
  end

  defp field_label(field) do
    field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  # -- Widgets tab --

  defp widgets_body(model) do
    p = model.widgets.progress

    state_label =
      cond do
        not model.widgets.working? -> "PAUSED"
        p == 100 -> "DONE"
        true -> "RUNNING"
      end

    vbox(
      constraints: [length: 3, length: 3, length: 3, length: 3, fill: 1],
      children: [
        widget_card(
          "Deployment progress",
          hbox(
            constraints: [fill: 1, length: 5],
            children: [
              progress(value: p, max: 100, fill_style: %Style{fg: :cyan}),
              text(" " <> String.pad_leading("#{p}%", 4))
            ]
          )
        ),
        widget_card(
          "Worker",
          hbox(
            constraints: [length: 2, length: 10, length: 13, fill: 1],
            children: [
              spinner(tick: model.tick, style: %Style{fg: :magenta}),
              text(state_label, style: %Style{bold: true}),
              button(if(model.widgets.working?, do: "Pause", else: "Resume"), focusable: :pause),
              checkbox("Loop when done", checked: model.widgets.loop?, focusable: :loop)
            ]
          )
        ),
        widget_card(
          "Statusbar (left / right)",
          statusbar(
            left: " #{state_label}  ",
            right: " tick: #{model.tick}  ",
            style: %Style{reverse: true, bold: true}
          )
        ),
        widget_card(
          "Keybar",
          keybar(
            bindings: [
              {?\s, "pause/resume"},
              {?1, "logs"},
              {?2, "form"},
              {?3, "widgets"},
              {?4, "keys"},
              {?5, "inputs"}
            ],
            separator: "  ·  ",
            right: " #{model.now} "
          )
        ),
        spacer()
      ]
    )
  end

  defp advance(%{working?: false, progress: p}), do: p
  defp advance(%{loop?: true, progress: p}), do: rem(p + 2, 101)
  defp advance(%{progress: p}), do: min(p + 2, 100)

  defp toggle_working(model),
    do: %{model | widgets: %{model.widgets | working?: not model.widgets.working?}}

  defp widget_card(title, child) do
    box(
      title: " " <> title <> " ",
      border: :rounded,
      border_style: %Style{fg: :bright_black},
      padding: {0, 1},
      child: child
    )
  end

  # -- Inputs tab --

  @sizes [small: "Small", medium: "Medium", large: "Large"]
  @deliveries [pickup: "Pickup", courier: "Courier", post: "Post"]
  @toppings [:mozzarella, :basil, :olives, :mushrooms, :chilli]
  @crusts [:thin, :classic, :stuffed]

  defp inputs_body(model) do
    i = model.inputs

    hbox(
      constraints: [fill: 1, length: 1, fill: 1],
      children: [
        vbox(
          constraints: [length: 5, length: 3, fill: 1],
          children: [
            pane(
              "Size · radio_group",
              :size,
              radio_group(focusable: :size, items: @sizes, value: i.size)
            ),
            pane(
              "Delivery · horizontal",
              :delivery,
              radio_group(
                focusable: :delivery,
                items: @deliveries,
                value: i.delivery,
                direction: :horizontal
              )
            ),
            pane(
              "Notes · textarea",
              :notes,
              textarea(
                focusable: :notes,
                value: i.notes,
                cursor: i.notes_cursor,
                wrap: true,
                placeholder: "Anything the kitchen should know",
                placeholder_style: [dim: true]
              )
            )
          ]
        ),
        spacer(),
        vbox(
          constraints: [length: 7, length: 5, length: 1, length: 1, fill: 1],
          children: [
            pane(
              "Toppings · check list",
              :toppings,
              list(@toppings,
                focusable: :toppings,
                focused_row: i.topping,
                selection: {:multi, i.toppings},
                marker: :checkbox
              )
            ),
            pane(
              "Crust · list box",
              :crust,
              list(@crusts, focusable: :crust, focused_row: i.crust)
            ),
            checkbox("Gift wrap", checked: i.gift, focusable: :gift),
            hbox(
              constraints: [length: 13, length: 12, fill: 1],
              children: [
                button([{"Save", bold: true}], focusable: :save_order),
                button("Reset", focusable: :reset_order),
                spacer()
              ]
            ),
            text(saved_line(i.saved), wrap: true)
          ]
        )
      ]
    )
  end

  defp pane(title, id, child) do
    box(title: " #{title} ", border: :rounded, focus_proxy: id, padding: {0, 1}, child: child)
  end

  defp saved_line(nil), do: [{"Nothing saved yet — Save shows the order here.", dim: true}]
  defp saved_line(summary), do: [{"✓ Saved: ", fg: :green, bold: true}, summary]

  defp inputs_defaults do
    %{
      size: :medium,
      delivery: :pickup,
      topping: :mozzarella,
      toppings: MapSet.new([:mozzarella]),
      crust: :classic,
      gift: false,
      notes: "",
      notes_cursor: 0,
      saved: nil
    }
  end

  defp put_input(model, key, value), do: %{model | inputs: Map.put(model.inputs, key, value)}

  defp order_summary(i) do
    toppings = @toppings |> Enum.filter(&(&1 in i.toppings)) |> Enum.join(", ")

    "#{i.size} #{i.crust}, #{if toppings == "", do: "no toppings", else: toppings}, " <>
      "#{i.delivery}#{if i.gift, do: ", gift wrapped", else: ""}"
  end

  # -- Keys tab --

  # The event list is focusable so that keys reach update/2 raw once it has
  # focus — on the tab bar, Left and Right switch tabs instead. It opts out of
  # the mouse, so a click inside it arrives raw too rather than focusing it.
  defp keys_body(model) do
    rows =
      case model.keys do
        [] ->
          [
            text("Tab here, then press keys: try Ctrl-Up, Shift-Right, Alt-A …",
              style: [dim: true]
            ),
            text("Click, right-click or scroll anywhere in this box.", style: [dim: true])
          ]

        keys ->
          Enum.map(keys, &text/1)
      end

    box(
      title: " events ",
      border: :rounded,
      border_style: %Style{fg: :bright_black},
      focus_proxy: :capture,
      handle_mouse: false,
      padding: {0, 1},
      child:
        vbox(
          focusable: :capture,
          handle_mouse: false,
          constraints: Enum.map(rows, fn _ -> {:length, 1} end) ++ [fill: 1],
          children: rows ++ [spacer()]
        )
    )
  end

  defp capture(model, ev), do: %{model | keys: Enum.take([format_event(ev) | model.keys], 12)}

  defp format_event({:key, key, mods}) do
    parts =
      Enum.map(mods, &Atom.to_string/1) ++
        [
          case key do
            {:char, c} when c in 32..126 -> "'#{<<c::utf8>>}'"
            {:char, c} -> "char(#{c})"
            {:f, n} -> "F#{n}"
            atom when is_atom(atom) -> Atom.to_string(atom)
          end
        ]

    "  " <> Enum.join(parts, " + ")
  end

  defp format_event({:key_repeat, k, m}), do: "  ↻ " <> format_event({:key, k, m})
  defp format_event({:key_release, k, m}), do: "  ↑ " <> format_event({:key, k, m})

  defp format_event({:mouse, action, button, col, row, mods}) do
    what = Enum.map_join(Enum.reject([action, button], &is_nil/1), " ", &Atom.to_string/1)
    held = Enum.map_join(mods, "", &"#{&1} + ")
    "  mouse #{held}#{what} at #{col},#{row}"
  end

  defp format_event(other), do: "  " <> inspect(other)

  # -- Status / key rows --

  defp status_row(model) do
    left =
      case model.tab do
        :logs -> "row #{model.logs.offset + 1}/#{length(@log_lines)}"
        :form -> "field: #{format_focus(Focus.current())}"
        :widgets -> if model.widgets.working?, do: "RUNNING", else: "PAUSED"
        :keys -> "captured: #{length(model.keys)}"
        :inputs -> "focus: #{format_focus(Focus.current())}"
      end

    statusbar(
      left: " #{left} ",
      right: " #{model.now} ",
      style: %Style{reverse: true}
    )
  end

  defp key_row(%{tab: :logs}),
    do:
      keybar(
        bindings: [
          {"Tab", "focus log"},
          {"↑↓", "scroll"},
          {"PgUp/PgDn", "page"},
          {"[ ]", "alert"},
          {"Shift-←→", "tab"},
          {?q, "quit"}
        ],
        separator: "  ·  "
      )

  defp key_row(%{tab: :form}),
    do:
      keybar(
        bindings: [
          {"Tab", "next field"},
          {"Shift-Tab", "prev field"},
          {"Shift-←→", "switch tab"},
          {"Ctrl-C", "quit"}
        ],
        separator: "  ·  "
      )

  defp key_row(%{tab: :widgets}),
    do:
      keybar(
        bindings: [
          {?\s, "pause / resume"},
          {"Tab", "button, checkbox"},
          {"Shift-←→", "switch tab"},
          {?q, "quit"}
        ],
        separator: "  ·  "
      )

  defp key_row(%{tab: :keys}),
    do:
      keybar(
        bindings: [
          {"Tab", "focus events"},
          {"any key", "captured"},
          {"Shift-←→", "switch tab"},
          {"Ctrl-C", "quit"}
        ],
        separator: "  ·  "
      )

  defp key_row(%{tab: :inputs}),
    do:
      keybar(
        bindings: [
          {"Tab", "next control"},
          {"↑↓←→", "choose"},
          {"Space", "tick"},
          {"Ctrl-C", "quit"}
        ],
        separator: "  ·  "
      )

  # -- helpers --

  defp tab_label(:logs), do: "Logs · 200 rows, scrollable, focus-aware"
  defp tab_label(:form), do: "Form · 14 fields, Tab cycles, scroll-into-view"
  defp tab_label(:widgets), do: "Widgets · progress, spinner, statusbar, keybar"
  defp tab_label(:keys), do: "Keys · press anything (try modified arrows)"
  defp tab_label(:inputs), do: "Inputs · radio groups, check list, list box, textarea"

  defp tab_for_digit(?1), do: :logs
  defp tab_for_digit(?2), do: :form
  defp tab_for_digit(?3), do: :widgets
  defp tab_for_digit(?4), do: :keys
  defp tab_for_digit(?5), do: :inputs

  defp cycle_tab(current, dir) do
    order = [:logs, :form, :widgets, :keys, :inputs]
    idx = Enum.find_index(order, &(&1 == current))
    n = length(order)
    Enum.at(order, rem(idx + dir + n, n))
  end

  defp input_focused?(model) do
    model.tab == :form and
      match?({:form_field, _}, Focus.current())
  end

  defp format_focus({:form_field, f}), do: Atom.to_string(f)
  defp format_focus(nil), do: "—"
  defp format_focus(id) when is_atom(id), do: Atom.to_string(id)
  defp format_focus(other), do: inspect(other)

  defp alert_rows do
    # Every 30th row gets surfaced as a "focusable" alert (cosmetic only —
    # the demo highlights it; the runtime doesn't actually focus into the
    # viewport's child for this demo).
    Enum.map(0..6, &(&1 * 30))
  end

  defp time_string do
    {h, m, s} = :erlang.time()

    "#{pad2(h)}:#{pad2(m)}:#{pad2(s)}"
  end

  @doc false
  # The options `--run` starts the app with. The tests start it with these too,
  # so a test cannot pass on an option the real app never sets.
  def run_opts, do: [mouse: true]

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end

case System.argv() do
  ["--run"] -> Harlock.run(ShowcaseApp, nil, ShowcaseApp.run_opts())
  _ -> :ok
end
