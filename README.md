# Harlock

[![Hex.pm](https://img.shields.io/hexpm/v/harlock.svg)](https://hex.pm/packages/harlock)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/harlock)
[![CI](https://github.com/thatsme/harlock/actions/workflows/ci.yml/badge.svg)](https://github.com/thatsme/harlock/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A pure-Elixir TUI framework for Unix terminals. TEA-style
model / update / view loop on top of OTP, with first-class focus
traversal, layout constraints, mouse support, ANSI cell-diff rendering,
and a small termios NIF for direct `/dev/tty` control.

![Harlock showcase](https://raw.githubusercontent.com/thatsme/harlock/v0.8.0/screenshots/showcase.jpg)

```elixir
defmodule Counter do
  use Harlock.App     # imports the view DSL (box/1, text/2, vbox/1, …)

  def init(_), do: %{n: 0}

  def update({:key, {:char, ?+}, []}, m), do: %{m | n: m.n + 1}
  def update({:key, {:char, ?-}, []}, m), do: %{m | n: max(0, m.n - 1)}
  def update({:key, {:char, ?q}, []}, _), do: :quit
  def update(_, m), do: m

  def view(m) do
    box(
      title: "Counter",
      border: :rounded,
      child: text("count: #{m.n}")
    )
  end
end

Harlock.run(Counter)
```

Run it with `mix run`. Not from an IEx prompt: IEx's own terminal driver reads
the same tty, and the app would not receive keystrokes.
Log output is held back while the app runs and printed after it exits, so a
`Logger` call does not draw over the screen.

A more realistic app wires focus traversal, a selectable table, a
scrollable viewport, and a side-effect via `Cmd` — all together. Tab
moves focus between the two boxes; the focused widget owns its keys.
Full source: [`examples/overview.exs`](https://github.com/thatsme/harlock/blob/main/examples/overview.exs).

```elixir
defmodule Overview do
  use Harlock.App
  alias Harlock.Cmd

  def init(_) do
    %{
      tasks: [
        %{id: 1, name: "compile", state: "done"},
        %{id: 2, name: "test", state: "running"},
        %{id: 3, name: "dialyzer", state: "queued"},
        %{id: 4, name: "credo", state: "queued"},
        %{id: 5, name: "publish", state: "blocked"}
      ],
      selected: 1,
      log: for(i <- 1..40, do: "[#{i}] event line #{i}"),
      log_offset: 0
    }
  end

  def update({:key, {:char, ?q}, []}, _), do: :quit

  def update({:key, {:char, ?r}, []}, m) do
    cmd =
      Cmd.from(fn -> Enum.map(1..3, &"[refresh] new line #{&1}") end)
      |> Cmd.map(fn lines -> {:refreshed, lines} end)

    {m, cmd}
  end

  def update({:refreshed, lines}, m), do: %{m | log: lines ++ m.log}

  # The runtime auto-routes scroll keys to the focused viewport and
  # delivers this message; the app just writes where the offset lives.
  def update({:harlock_scroll, :log, new_offset}, m), do: %{m | log_offset: new_offset}

  # A focused table routes row movement too, so there is no key dispatch here.
  def update({:harlock_select, :tasks, id}, m), do: %{m | selected: id}

  def update(_, m), do: m

  def view(m) do
    vbox(
      constraints: [fill: 1, length: 1],
      children: [
        hbox(
          constraints: [percentage: 40, fill: 1],
          children: [
            box(
              title: "Tasks",
              border: :rounded,
              border_style: [dim: true],
              focus_style: [fg: :cyan, bold: true],
              # :tasks lives on the table so row movement routes to it; the box
              # mirrors its focus for the border.
              focus_proxy: :tasks,
              child:
                table(
                  focusable: :tasks,
                  columns: [
                    column(title: "#", width: {:length, 3}, render: &Integer.to_string(&1.id)),
                    column(title: "name", width: {:fill, 1}, render: & &1.name),
                    column(title: "state", width: {:length, 8}, render: & &1.state)
                  ],
                  rows: m.tasks,
                  row_id: & &1.id,
                  focused_row: m.selected,
                  selection: {:single, m.selected}
                )
            ),
            box(
              title: "Log",
              border: :rounded,
              border_style: [dim: true],
              focus_style: [fg: :cyan, bold: true],
              # :log lives on the viewport, because that is what receives the
              # scroll keys. focus_proxy: lights the box up with it.
              focus_proxy: :log,
              child:
                viewport(
                  focusable: :log,
                  offset: m.log_offset,
                  content_height: length(m.log),
                  child:
                    vbox(
                      constraints: List.duplicate({:length, 1}, length(m.log)),
                      children: Enum.map(m.log, &text/1)
                    )
                )
            )
          ]
        ),
        text("Tab focus  arrows/PgUp/PgDn or wheel scroll  click select  r refresh  q quit",
          style: [dim: true]
        )
      ]
    )
  end
end

Harlock.run(Overview, nil, mouse: true)
```

## Installation

```elixir
def deps do
  [{:harlock, "~> 0.9"}]
end
```

Harlock builds a small termios NIF (`c_src/termios.c`) and an exec helper
(`c_src/exec_helper.c`, installed as `priv/harlock_exec`, which `Cmd.exec`
uses to run programs with the terminal) — `elixir_make` handles both
automatically. Requires a C compiler and `make` available at install time. macOS, Linux, and
\*BSD are supported; Windows native is not (WSL works).

## Why Harlock

If you've written a Phoenix LiveView app you already know how to use
Harlock — `init / update / view`, message-passing for events,
side-effects as `Cmd` values. The runtime is a single OTP supervision
tree: terminal owner → IO → cmd executor → TEA loop. Any crash shuts the
tree down and the terminal owner restores the tty — checked in a real pty
for crashes, killed supervisors, and programs started with `Cmd.exec`.

Compared to alternatives:

- **[Owl](https://hex.pm/packages/owl)** is a styled-output library
  ("println but pretty"). Harlock is a full interactive runtime —
  focus, layout, dirty-flag rendering, async cmds, resize handling.
- **[Ratatouille](https://hex.pm/packages/ratatouille)** wraps termbox
  via a C port. Solid, but the C dep is bigger and the runtime model
  is its own thing. Harlock is pure Elixir for rendering, with a small
  in-process NIF only for terminal control — closer to "Elixir all the
  way down" if that matters to you.
- **ratatui-via-port** approaches (Rust binary speaking a wire
  protocol to BEAM) ship as two artifacts: your Elixir release plus a
  separately-compiled Rust binary that has to be on `PATH` at runtime.
  Harlock ships as one mix dependency — its only native pieces build
  from source with it, and there is no version-skew between BEAM and
  renderer. The element tree is also ordinary Elixir
  data, which makes testing and composition easier than a wire-protocol
  boundary.

## Status

Harlock is `v0.9`. The API is intentionally narrow and stable for the
primitives it ships; widgets and ergonomics are still landing.
Anything `@moduledoc false` is internal and free to change.

| Area | Status |
|---|---|
| TEA runtime (`init` / `update` / `view` / `subs`) | ✓ |
| OTP supervision + terminal restoration | ✓ |
| Cmd executor (`Cmd.from`, `Cmd.batch`, `Cmd.map`) | ✓ |
| Running another program with the terminal (`Cmd.exec`) | ✓ (v0.8) |
| Job control: Ctrl-Z / `fg` (`Cmd.suspend`) | ✓ (v0.8; Ctrl-Z inside a `Cmd.exec` program v0.9) |
| Layout constraints (`:length`, `:percentage`, `:fill`, `:min`, `:max`) | ✓ |
| Focus traversal + focus_trap overlays | ✓ |
| Focus-aware key routing (`viewport` / `tabs` / `text_input` / `textarea` / `menu` / `select` / `tree` / `table` / `button` / `checkbox` / `radio_group`) | ✓ |
| Wide-grapheme width (CJK, emoji, ZWJ, flags) | ✓ |
| Log output held back while an app runs, printed after it exits | ✓ (v0.9) |
| Theme tokens (`:header`, `:focus`, `:selection`, `:border`, `:primary`, `:accent`, `:muted`, `:error`) | ✓ (full set in v0.4) |
| Built-in themes (`:default` / `:dark` / `:high_contrast`) | ✓ (v0.4) |
| Caps-aware color downgrade (truecolor → 256 → 16 → mono) | ✓ (v0.4) |
| Table style cascade (`:header_style` / `:row_style` / `:alt_row_style` / `:selected_style` / `:focus_style`) | ✓ (v0.4) |
| `:default` theme byte-identical to v0.3 (golden-frame pin) | ✓ (v0.4) |
| Terminal resize reflows (SIGWINCH, `ioctl(TIOCGWINSZ)`) | ✓ (v0.8; broken before) |
| `text` / `vbox` / `hbox` / `box` / `spacer` / `overlay` / `table` / `list` / `text_input` | ✓ |
| Styled runs, newlines, wrap and align in `text` (`Harlock.Text`) | ✓ (v0.8) |
| `button` / `checkbox` | ✓ (v0.8) |
| `radio_group`; `list` as a list box and, with `marker: :checkbox`, a check list | ✓ (v0.9) |
| Focus changes delivered to `update/2` (`{:harlock_focus, from, to}`) | ✓ (v0.9) |
| Readline editing in `text_input` / `textarea` (word motions, kills) | ✓ (v0.4.2) |
| Yank (`Ctrl-Y`) in routed inputs, one kill ring per app | ✓ (v0.8) |
| `progress` / `spinner` / `statusbar` / `keybar` / `tabs` | ✓ |
| `viewport` (render-then-clip + scroll-into-view + cursor remap) | ✓ |
| `:telemetry` events (frame render, input dispatch, cmd, reader) | ✓ |
| Modified arrows / Home / End / F-keys (parser) | ✓ |
| Mouse: clicks on elements and the items inside them, wheel scrolls (`mouse: true`) | ✓ (v0.8; `textarea`, radio, check-list and `focus_proxy` border clicks v0.9) |
| Kitty keyboard protocol (parser) | ✓ (parser only — runtime push deferred) |
| `tree` / `menu` / `select` widgets | ✓ (v0.5) |
| Multi-line `textarea` with opt-in word wrap | ✓ (v0.4.2) |
| Goal-column memory for `textarea` vertical motion | ✓ (v0.4.3) |
| Undo / redo (`Harlock.UndoStack`, app-held) | ✓ (v0.5) |
| Push-shaped `Sub` kinds (`telemetry` / `logger` / `source`) | ✓ (v0.6; `source` v0.7) |
| `Sub` kinds with real logic (`file` / `port`) | 1.1+ |
| Windowed `table` rows (`fn offset, limit -> rows`) | ✓ (v0.7) |
| `sparkline` widget | ✓ (v0.6) |
| `box(focus_proxy: id)` (visual focus mirroring) | ✓ (v0.6) |

See [`ROADMAP.md`](ROADMAP.md) for the full plan through v1.0.

## Examples

```sh
./scripts/run.sh counter    # simplest possible app — count up/down, by key or button
./scripts/run.sh sysmon     # live BEAM process monitor: sort, pause, dialogs with buttons, mouse
./scripts/run.sh contacts   # contact manager: search, list, dialog with buttons, mouse
./scripts/run.sh showcase   # tabs, viewport, widgets, form inputs, key and mouse events
./scripts/run.sh notes      # multi-line textarea: wrap toggle, readline editing, undo, click to place
./scripts/run.sh explorer   # tree + select + menu: async-loaded nodes, focus changes, mouse
./scripts/run.sh dashboard  # telemetry + logger subscriptions: sparkline, scrollable log, controls
./scripts/run.sh nodes      # BEAM node explorer: windowed table, lazy supervision tree, mouse
./scripts/run.sh overview   # the README's second snippet: table, viewport, Cmd, mouse
./scripts/run.sh editor     # file browser: open files in $VISUAL/$EDITOR, Ctrl-Z, mouse
```

The `scripts/run.sh` wrapper is in the GitHub repo — clone the repo to
run the examples. The hex package itself is the library; apps depend
on `:harlock` and build their own runtime entry point (see the Counter
snippet above).

Every example runs with the mouse on and has tests under `test/examples`, which
start each one with the options its `--run` uses and fail if any example
compiles with a warning.

`contacts` exercises most of the core primitives: tab focus traversal,
text_input fields, buttons and a checkbox, an overlay with focus_trap,
async save via `Cmd.from`, styled text, a custom theme, a status bar with
a current-focus indicator, and the mouse.

`showcase` is a five-tab tour of the widgets — a clickable tab
bar, a 200-row log viewer with `viewport` + scrollbar and styled levels, a
long form that uses scroll-into-view to keep the focused field visible, a
widget gallery with animated progress/spinner/statusbar/keybar and a
button and checkbox driving them, an event inspector for modified arrows
(Ctrl-Up, Alt-Left, etc.) and the raw mouse events an app receives, and an
order form with radio groups, a check list, a list box and a textarea.

`nodes` is a BEAM node explorer — `observer` for people on SSH — and the
largest example: a process list, supervision trees, and memory over time. It
shows the two patterns that matter for real data. The process table uses a
window function, because enumerating pids is one cheap list while
`Process.info/2` on all of them is not, so only the rows about to be drawn get
hydrated. The supervision tree loads children through a `Cmd` on expansion,
because `which_children/1` is a call into another process and the window
function runs during rendering. With the mouse, the tabs switch on a click, the
wheel scrolls the process list, a click on a process shows its status, current
function, links and queue underneath, and a click on a marker expands a
supervisor.

`dashboard` wires two push subscriptions into one screen: `Sub.telemetry`
feeds job durations to a `sparkline`, `Sub.logger` turns log calls into
`update/2` messages, and `Sub.interval` drives the workload. It emits its own
telemetry because a standalone example has nothing else to listen to — but the
work runs inside a `Cmd`, so the handler fires in a different process from the
UI exactly as it would for a real query. Point the same subscription at
`[:ecto, :repo, :query]` and only the transform changes, to read Ecto's
`:total_time` — in native time units — instead of `:duration`. Pausing removes only the interval from
`subs/1`, so the runtime visibly stops one subscription and leaves the others
running. A radio group sets the workload's size, Pause and
Clear are buttons as well as keys, and the log keeps a scrollable history,
newest first, whose view holds still while new lines arrive above it.

`editor` is a file browser that hands the terminal to your editor. Enter, or
the "Open in editor" button, runs `$VISUAL`, then `$EDITOR`, then `vi` on the
selected file through `Cmd.exec`; the app redraws and reloads the preview when
the editor exits. Ctrl-Z suspends to the shell through `Cmd.suspend`, and the
mouse selects files, presses the button and scrolls the preview. Without a
directory argument it works on a scratch directory of sample files.

`explorer` puts `tree`, `select` and `menu` in one app. Its `deps` node
starts with nothing loaded: expanding it marks the node in flight, returns
a `Cmd`, and the fetched children arrive as an ordinary message — the
pattern any tree over a filesystem or a remote node needs. The filter
dropdown opens over the actions and closes when focus leaves it, by Tab or
by a click elsewhere, through `{:harlock_focus, from, to}`. The filtered node
list is rebuilt from the model in `view/1` rather than handed to the widget,
because the model owns what is displayed. The mouse works throughout: node
markers, rows, filter choices, actions, and pane borders.

`sysmon` is a live process table refreshed on a timer. A radio group picks the
sort order, unticking Live drops the interval from `subs/1` so the rows hold
still for reading, and help and quit are overlays with buttons that trap
focus while `y`, `n` and Esc keep working.

`notes` is one `textarea` and one `update/2` clause for every edit: typing,
word motions and kills, vertical motion that keeps its goal column, and a click
that places the cursor all arrive as the same `{:harlock_edit, …}` message.
Undo and redo come from `Harlock.UndoStack`, held in the model.

## Testing your app

`Harlock.Test` boots an app under a headless backend — no `/dev/tty`
required — and exposes synchronous helpers:

```elixir
test "Tab cycles focus through the form" do
  h = Harlock.Test.start_app(MyApp, init_arg)

  Harlock.Test.send_key(h, :tab)
  assert Harlock.Test.focused(h) == :email

  Harlock.Test.send_key(h, :tab)
  assert Harlock.Test.focused(h) == :submit

  Harlock.Test.stop(h)
end
```

Same code path as the real runtime — only the bytes-in / bytes-out
boundary is mocked.

## Smoke tests

The scripts in `priv/*_smoke.exs` exercise the real runtime and termios NIF
in a pty via `script(1)`: resize, crash restoration, `Cmd.exec` with typed
input and Ctrl-Z inside the program it runs, suspend under a job-control shell,
mouse reporting, log output held back while an app runs, and two examples. They
run in CI.

```sh
./scripts/smoke.sh
```

Picks the right flag syntax for BSD vs util-linux `script` automatically.

## Contributing

Issues and PRs welcome at <https://github.com/thatsme/harlock>. The
codebase is about 11k lines of Elixir and 1k lines of C. Start with `lib/harlock/app/runtime.ex` — everything
else is reachable from there.

## License

MIT. See [`LICENSE`](LICENSE).
