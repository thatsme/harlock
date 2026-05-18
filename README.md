# Harlock

[![Hex.pm](https://img.shields.io/hexpm/v/harlock.svg)](https://hex.pm/packages/harlock)
[![Hex Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/harlock)
[![CI](https://github.com/thatsme/harlock/actions/workflows/ci.yml/badge.svg)](https://github.com/thatsme/harlock/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

A pure-Elixir TUI framework for Unix terminals. TEA-style
model / update / view loop on top of OTP, with first-class focus
traversal, layout constraints, ANSI cell-diff rendering, and a small
termios NIF for direct `/dev/tty` control.

![Harlock showcase](https://raw.githubusercontent.com/thatsme/harlock/v0.3.0/screenshots/showcase.jpg)

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

A more realistic app wires focus traversal, a selectable table, a
scrollable viewport, and a side-effect via `Cmd` — all together. Tab
moves focus between the two boxes; the focused widget owns its keys.
Full source: [`examples/overview.exs`](examples/overview.exs).

```elixir
defmodule Overview do
  use Harlock.App
  alias Harlock.{Cmd, Focus, Viewport}

  @log_visible 10

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

  def update({:key, key, _} = ev, m) do
    case Focus.current() do
      :tasks ->
        update_tasks(ev, m)

      :log ->
        %{m | log_offset: Viewport.apply_key(m.log_offset, length(m.log), @log_visible, key)}

      _ ->
        m
    end
  end

  def update(_, m), do: m

  defp update_tasks({:key, :up, _}, m), do: %{m | selected: max(1, m.selected - 1)}

  defp update_tasks({:key, :down, _}, m),
    do: %{m | selected: min(length(m.tasks), m.selected + 1)}

  defp update_tasks(_, m), do: m

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
              focusable: :tasks,
              child:
                table(
                  columns: [
                    column(title: "#", width: {:length, 3}, render: &Integer.to_string(&1.id)),
                    column(title: "name", width: {:fill, 1}, render: & &1.name),
                    column(title: "state", width: {:length, 8}, render: & &1.state)
                  ],
                  rows: m.tasks,
                  row_id: & &1.id,
                  selection: {:single, m.selected}
                )
            ),
            box(
              title: "Log",
              border: :rounded,
              focusable: :log,
              child:
                viewport(
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
        text("Tab focus  arrows/PgUp/PgDn scroll  r refresh  q quit", style: [dim: true])
      ]
    )
  end
end

Harlock.run(Overview)
```

## Installation

```elixir
def deps do
  [{:harlock, "~> 0.3"}]
end
```

Harlock builds a small C NIF (`c_src/termios.c`, ~250 LOC of POSIX) for
termios access — `elixir_make` handles this automatically. Requires a
C compiler and `make` available at install time. macOS, Linux, and
\*BSD are supported; Windows native is not (WSL works).

## Why Harlock

If you've written a Phoenix LiveView app you already know how to use
Harlock — `init / update / view`, message-passing for events,
side-effects as `Cmd` values. The runtime is a single OTP supervision
tree: terminal owner → IO → cmd executor → TEA loop, with terminal
restoration guaranteed on any crash path via the supervisor's
`rest_for_one` strategy.

Compared to alternatives:

- **[Owl](https://hex.pm/packages/owl)** is a styled-output library
  ("println but pretty"). Harlock is a full interactive runtime —
  focus, layout, dirty-flag rendering, async cmds, resize handling.
- **[Ratatouille](https://hex.pm/packages/ratatouille)** wraps termbox
  via a C port. Solid, but the C dep is bigger and the runtime model
  is its own thing. Harlock is pure-Erlang for rendering with a small
  in-process NIF only for termios — closer to "Elixir all the way
  down" if that matters to you.
- **ratatui-via-port** approaches (Rust binary speaking a wire
  protocol to BEAM) ship as two artifacts: your Elixir release plus a
  separately-compiled Rust binary that has to be on `PATH` at runtime.
  Harlock ships as one mix release — no extra binary, no version-skew
  between BEAM and renderer. The element tree is also ordinary Elixir
  data, which makes testing and composition easier than a wire-protocol
  boundary.

## Status

Harlock is `v0.3`. The API is intentionally narrow and stable for the
primitives it ships; widgets and ergonomics are still landing.
Anything `@moduledoc false` is internal and free to change.

| Area | v0.3 |
|---|---|
| TEA runtime (`init` / `update` / `view` / `subs`) | ✓ |
| OTP supervision + terminal restoration | ✓ |
| Cmd executor (`Cmd.from`, `Cmd.batch`, `Cmd.map`) | ✓ |
| Layout constraints (`:length`, `:percentage`, `:fill`, `:min`, `:max`) | ✓ |
| Focus traversal + focus_trap overlays | ✓ |
| Wide-grapheme width (CJK, emoji, ZWJ, flags) | ✓ |
| Theme tokens (`:header`, `:focus`, `:selection`, `:border`) | ✓ |
| SIGWINCH resize via `ioctl(TIOCGWINSZ)` NIF | ✓ |
| `text` / `vbox` / `hbox` / `box` / `spacer` / `overlay` / `table` / `list` / `text_input` | ✓ |
| `progress` / `spinner` / `statusbar` / `keybar` / `tabs` | ✓ |
| `viewport` (render-then-clip + scroll-into-view + cursor remap) | ✓ |
| `:telemetry` events (frame render, input dispatch, cmd, reader) | ✓ |
| Modified arrows / Home / End / F-keys (parser) | ✓ |
| Mouse events (SGR parser) | ✓ (parser only — runtime enabling deferred) |
| Kitty keyboard protocol (parser) | ✓ (parser only — runtime push deferred) |
| Full theme set + built-in themes + color downgrade | v0.4 |
| `tree` / `menu` / `select` widgets | v0.4 |
| Multi-line `text_area` | v0.4 |

See [`ROADMAP.md`](ROADMAP.md) for the full plan through v1.0.

## Examples

```sh
./scripts/run.sh counter    # simplest possible app — count up/down
./scripts/run.sh sysmon     # live BEAM process monitor
./scripts/run.sh contacts   # contact manager: search, list, modal forms, async save
./scripts/run.sh showcase   # tabs, viewport, widgets, modified keys
```

The `scripts/run.sh` wrapper is in the GitHub repo — clone the repo to
run the examples. The hex package itself is the library; apps depend
on `:harlock` and build their own runtime entry point (see the Counter
snippet above).

`contacts` exercises most of the core primitives: tab focus traversal,
text_input fields, an overlay with focus_trap, async save via
`Cmd.from`, custom theme, status bar with current-focus indicator.

`showcase` is a four-tab tour of everything that landed in v0.3 — a
200-row scrollable log viewer with `viewport` + scrollbar, a long form
that uses scroll-into-view to keep the focused field visible, a
widget gallery with animated progress/spinner/statusbar/keybar, and a
key-event inspector you can use to try out modified arrows
(Ctrl-Up, Shift-Right, etc.).

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

A handful of scripts in `priv/*_smoke.exs` exercise the real
runtime + termios NIF via `script(1)`:

```sh
./scripts/smoke.sh
```

Picks the right flag syntax for BSD vs util-linux `script` automatically.

## Contributing

Issues and PRs welcome at <https://github.com/thatsme/harlock>. The
codebase is small enough (~3k LOC of Elixir + ~250 LOC of C) to read
in an afternoon. Start with `lib/harlock/app/runtime.ex` — everything
else is reachable from there.

## License

MIT. See [`LICENSE`](LICENSE).
