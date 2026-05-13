# Harlock

A pure-Elixir TUI framework for Unix terminals. TEA-style
model / update / view loop on top of OTP, with first-class focus
traversal, layout constraints, ANSI cell-diff rendering, and a small
termios NIF for direct `/dev/tty` control.

```elixir
defmodule Counter do
  use Harlock.App

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

## Installation

```elixir
def deps do
  [{:harlock, "~> 0.2"}]
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
  protocol to BEAM) are reliable but you give up the testability and
  composability of pure-Elixir element trees. Harlock keeps the view
  tree as ordinary data structures.

## Status

Harlock is `v0.2`. The API is intentionally narrow and stable for the
primitives it ships; widgets and ergonomics are still landing.
Anything `@moduledoc false` is internal and free to change.

| Area | v0.2 |
|---|---|
| TEA runtime (init/update/view/subs) | ✓ |
| OTP supervision + terminal restoration | ✓ |
| Cmd executor (`Cmd.from`, `Cmd.batch`, `Cmd.map`) | ✓ |
| Layout constraints (`:length`, `:percentage`, `:fill`) | ✓ |
| Focus traversal + focus_trap overlays | ✓ |
| Wide-grapheme width (CJK, emoji, ZWJ, flags) | ✓ |
| Theme tokens (`:header`, `:focus`, `:selection`, `:border`) | ✓ |
| SIGWINCH resize via `ioctl(TIOCGWINSZ)` NIF | ✓ |
| `text` / `vbox` / `hbox` / `box` / `spacer` / `overlay` / `table` / `list` / `text_input` | ✓ |
| `viewport`, `progress`, `tabs`, `spinner`, `statusbar`, `keybar` | v0.3 |
| `:min` / `:max` layout constraints (currently behave as `:length`) | v0.3 |
| Mouse, kitty keyboard protocol, modified arrows | v0.3 |
| Full theme set + built-in themes + color downgrade | v0.4 |

See [`ROADMAP.md`](ROADMAP.md) for the full plan through v1.0.

## Examples

```sh
./scripts/run.sh counter    # simplest possible app — count up/down
./scripts/run.sh sysmon     # live BEAM process monitor
./scripts/run.sh contacts   # contact manager: search, list, modal forms, async save
```

`contacts` exercises most of v0.2: tab focus traversal, text_input
fields, an overlay with focus_trap, async save via `Cmd.from`, custom
theme, status bar with current-focus indicator.

<!--
To record an asciinema demo of the contacts app:

  asciinema rec --command './scripts/run.sh contacts' demo.cast
  asciinema upload demo.cast

Then replace this comment with the embed:

  [![asciicast](https://asciinema.org/a/<CAST_ID>.svg)](https://asciinema.org/a/<CAST_ID>)
-->


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
