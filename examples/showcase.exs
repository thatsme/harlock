# Showcase — a multi-tab demo of everything that landed in Harlock v0.3:
#
#   - `tabs/1`         — horizontal tab bar
#   - `viewport/1`     — scrollable container with scroll-into-view
#   - `progress/1`     — bar widget driven by a Sub.interval
#   - `spinner/1`      — single-cell animator
#   - `statusbar/1`    — pinned top/bottom row helper
#   - `keybar/1`       — context-aware shortcut row
#   - Modified arrows  — Ctrl/Shift/Alt + arrow keys (Keys tab shows them)
#
# Run from the project root:
#
#   ./scripts/run.sh showcase
#
# Tabs (Left/Right or 1-4 to switch):
#
#   1. Logs    — viewport scrolling over 200 lines, scrollbar, focus follows
#   2. Form    — 14 text_inputs inside a viewport; Tab cycles fields and
#                scroll-into-view + cursor remap keep the focused field visible
#   3. Widgets — progress bar + spinner + animated statusbar via Sub.interval
#   4. Keys    — captures and displays the last 12 key events (use this to try
#                modified arrows like Ctrl-Up, Shift-Right, etc.)
#
# Quit: Ctrl-C from anywhere, or 'q' when the tab bar / logs tab is focused.

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

                "#{String.pad_leading(Integer.to_string(i), 3)}  #{level}  #{service}  #{msg}"
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
      widgets: %{progress: 0, working?: true}
    }
  end

  def subs(_model), do: [Harlock.Sub.interval(100, :tick)]

  # ----- update -----

  def update({:key, {:char, ?c}, [:ctrl]}, _model), do: :quit

  def update(:tick, model) do
    progress = if model.widgets.working?, do: rem(model.widgets.progress + 2, 101), else: 100

    %{
      model
      | tick: model.tick + 1,
        now: time_string(),
        widgets: %{model.widgets | progress: progress}
    }
  end

  # Tab switching: 1-4 number keys (when not inside the Form tab where it
  # would be typed into a field), and Ctrl-Left / Ctrl-Right.
  def update({:key, {:char, c}, []}, model)
      when c in [?1, ?2, ?3, ?4] and model.tab != :form do
    %{model | tab: tab_for_digit(c)}
  end

  def update({:key, :right, [:shift]}, model), do: %{model | tab: cycle_tab(model.tab, +1)}
  def update({:key, :left, [:shift]}, model), do: %{model | tab: cycle_tab(model.tab, -1)}

  # 'q' quits only when no input is focused.
  def update({:key, {:char, ?q}, []}, model) do
    if input_focused?(model), do: model, else: :quit
  end

  # Keys tab: capture every key event verbatim into the history.
  def update({:key, _, _} = ev, %{tab: :keys} = model) do
    %{model | keys: Enum.take([format_event(ev) | model.keys], 12)}
  end

  # Logs tab: scrolling is now routed by the runtime via :logs_viewport
  # (v0.4 R2). Tab is used by the runtime for focus traversal, so alert
  # cycling moved to `[` / `]`.
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

  # Form tab: routed text-input edit — the runtime auto-routes the focused
  # field's apply_key result to this clause (v0.4 R2).
  def update({:harlock_edit, {:form_field, field}, {v, c}}, model) do
    new_values = Map.put(model.form.values, field, v)
    new_cursors = Map.put(model.form.cursors, field, c)
    %{model | form: %{model.form | values: new_values, cursors: new_cursors}}
  end

  # Widgets tab: space toggles working/paused.
  def update({:key, {:char, ?\s}, []}, %{tab: :widgets} = model) do
    %{model | widgets: %{model.widgets | working?: not model.widgets.working?}}
  end

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
    text(
      " Harlock v0.3 Showcase " <>
        String.duplicate(" ", 80) <> " viewport · tabs · widgets · modified keys ",
      style: %Style{bold: true, fg: :cyan, reverse: true}
    )
  end

  defp tab_bar(model) do
    tabs(
      items: [
        {:logs, "1. Logs"},
        {:form, "2. Form"},
        {:widgets, "3. Widgets"},
        {:keys, "4. Keys"}
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

  defp log_line(line, _idx, true) do
    text("▶ " <> line, style: %Style{bold: true, fg: :yellow})
  end

  defp log_line(line, _idx, false) do
    style =
      cond do
        String.contains?(line, "ERROR") -> %Style{fg: :red}
        String.contains?(line, "WARN") -> %Style{fg: :yellow}
        String.contains?(line, "DEBUG") -> %Style{dim: true}
        true -> %Style{}
      end

    text("  " <> line, style: style)
  end

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
            constraints: [length: 2, fill: 1],
            children: [
              spinner(tick: model.tick, style: %Style{fg: :magenta}),
              text("   " <> state_label, style: %Style{bold: true})
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
              {?4, "keys"}
            ],
            separator: "  ·  ",
            right: " #{model.now} "
          )
        ),
        spacer()
      ]
    )
  end

  defp widget_card(title, child) do
    box(
      title: " " <> title <> " ",
      border: :rounded,
      border_style: %Style{fg: :bright_black},
      padding: {0, 1},
      child: child
    )
  end

  # -- Keys tab --

  defp keys_body(model) do
    rows =
      case model.keys do
        [] -> [text("Press any key. Try Ctrl-Up, Shift-Right, Alt-A …", style: %Style{dim: true})]
        keys -> Enum.map(keys, &text/1)
      end

    vbox(
      constraints: Enum.map(rows, fn _ -> {:length, 1} end) ++ [fill: 1],
      children: rows ++ [spacer()]
    )
  end

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
  defp format_event(other), do: "  " <> inspect(other)

  # -- Status / key rows --

  defp status_row(model) do
    left =
      case model.tab do
        :logs -> "row #{model.logs.offset + 1}/#{length(@log_lines)}"
        :form -> "field: #{format_focus(Focus.current())}"
        :widgets -> if model.widgets.working?, do: "RUNNING", else: "PAUSED"
        :keys -> "captured: #{length(model.keys)}"
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
          {"Shift-←→", "switch tab"},
          {?q, "quit"}
        ],
        separator: "  ·  "
      )

  defp key_row(%{tab: :keys}),
    do:
      keybar(
        bindings: [
          {"any key", "captured"},
          {"Shift-←→", "switch tab"},
          {"Ctrl-C", "quit"}
        ],
        separator: "  ·  "
      )

  # -- helpers --

  defp tab_label(:logs), do: "Logs · 200 rows, scrollable, focus-aware"
  defp tab_label(:form), do: "Form · 14 fields, Tab cycles, scroll-into-view"
  defp tab_label(:widgets), do: "Widgets · progress, spinner, statusbar, keybar"
  defp tab_label(:keys), do: "Keys · press anything (try modified arrows)"

  defp tab_for_digit(?1), do: :logs
  defp tab_for_digit(?2), do: :form
  defp tab_for_digit(?3), do: :widgets
  defp tab_for_digit(?4), do: :keys

  defp cycle_tab(current, dir) do
    order = [:logs, :form, :widgets, :keys]
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

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end

case System.argv() do
  ["--run"] -> Harlock.run(ShowcaseApp, nil)
  _ -> :ok
end
