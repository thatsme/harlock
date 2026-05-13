# Changelog

All notable changes to Harlock will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While on `0.x`, the public API may break between minor versions. Breaking
changes are called out in the relevant release notes.

## [Unreleased]

### Added

- Real `:min` and `:max` layout constraints. `{:min, n}` reserves at
  least `n` cells and grows like a fill (weight 1) if there's room.
  `{:max, n}` behaves like a fill (weight 1) capped at `n` — the
  excess from a hit cap redistributes to other flexible slots until
  the solver converges. If `:max` caps leave space unallocated
  (e.g. `[max: 10, max: 10]` in a 30-cell region), the trailing
  region is simply unused rather than overflowing a cap.
- Standard widgets (composable from existing primitives, dumb
  renderers with app-owned state):
  - `progress(value:, max:, width:, style:, fill_style:)` — single-line
    bar, integer cell fill.
  - `spinner(tick:, frames:, style:)` — single cell, frame cycled by
    caller's tick counter (typically driven by `Sub.interval`).
  - `statusbar(left:, right:, style:)` — pinned-row helper with left /
    right alignment and middle padding.
  - `keybar(bindings:, separator:, right:, style:)` — formats
    `[k] label  [k] label` from a list of `{key, label}` tuples.
  - `tabs(items:, active:, focusable:, style:, active_style:, separator:)` —
    single-line tab bar; active tab gets `Theme.get(:focus)` when the
    widget is focused, `Theme.get(:header)` when not.
- `Harlock.Tabs.apply_key/3` — pure helper mapping Left/Right/Home/End
  key events to `{:select, id} | :noop`, mirroring the `TextBuffer`
  pattern.

### Removed

- The v0.2 `validate_constraints!` that raised on `:min`/`:max` — those
  constraints now work, so the guard isn't needed.

## [0.2.0] — 2026-05-13

First Hex release. Adds the Cmd executor, SIGWINCH-driven resize, wide-
grapheme width, minimal theme tokens, `text_input`, and a termios NIF
for direct `/dev/tty` control. The library is ready to depend on as
`{:harlock, "~> 0.2"}`.

### Added

- v0.2-prep tooling baseline: `ex_doc`, `dialyxir`, `credo` dev deps;
  `mix docs` config; `.credo.exs` tuned green; Dialyzer baseline clean;
  GitHub Actions CI running format check, warnings-as-errors compile,
  tests, Credo, and Dialyzer.
- `Harlock.Cmd` executor. `Cmd.from/1` runs a 0-arity function under a
  per-app `Task.Supervisor` and delivers its return value as a
  `{:harlock_event, _}` message; `Cmd.batch/1` dispatches a list
  concurrently; `Cmd.map/2` transforms results before delivery, with
  nested maps applying inner-first. Task crashes are caught and surfaced
  as `{:cmd_error, reason}` events without taking down the runtime. Cmds
  returned from `init/1` are dispatched after the first render; cmds
  returned alongside `:quit` are dispatched before the runtime exits.

- SIGWINCH-driven terminal resize. `Keeper` installs an
  `:os.set_signal(:sigwinch, :handle)` handler in init/1; on signal it
  queries the new size via `ioctl(TIOCGWINSZ)` through the termios NIF
  and forwards `{:harlock_resize, rows, cols}` to the runtime, which
  discards `prev_frame` (full redraw at the new size) and re-renders.
  The handler is removed on Keeper terminate so it doesn't leak past
  process death.
- `Termios.winsize/1` — TIOCGWINSZ via the NIF, also used by
  `Runtime.detect_size` for the initial frame dimensions.
- `Harlock.Test.resize/3` — synthetic resize event for headless tests.
  Resizes the test writer's cell buffer in lockstep so the next frame
  has somewhere to land.
- `Harlock.Width` — display-column width for terminal rendering. Handles
  East Asian Wide / Fullwidth, emoji, regional-indicator flag pairs,
  combining marks, ZWJ, and variation selectors. Public surface:
  `width/1`, `string_width/1`, `slice/2`, `pad_trailing/3`,
  `pad_leading/3`. Ranges sourced from Unicode 15.1 EastAsianWidth.txt.
- `Harlock.Theme` — minimal theme tokens (`:header`, `:focus`,
  `:selection`, `:border`). Apps configure via `Harlock.run(MyApp,
  arg, theme: %Theme{...})`; omitted = `Theme.default/0` which matches
  the pre-theming hard-coded values byte-for-byte. `Theme.get/1` is
  available inside `view/1` and `update/2` via the process dict, same
  pattern as `Harlock.Focus`. Full token set (`:primary`, `:accent`,
  `:muted`, `:error`) plus built-in themes and color downgrade still
  land in v0.4.
- `Style.merge/2` — layer one style on top of another (non-default
  colors win, booleans OR). Used to apply theme `:focus` to user-set
  element styles without losing fg/bg.
- `Harlock.TextBuffer` — pure helpers for editing a `(value, cursor)`
  pair: `insert/3`, `delete_backward/2`, `delete_forward/2`, cursor
  movement, plus `apply_key/3` mapping a key event to
  `{:edit, value, cursor} | :submit | :noop`. Cursor is a grapheme
  index; `cursor_column/2` translates to display columns via
  `Harlock.Width` (CJK and combining-mark aware).
- `text_input` element — single-line input with `:value`, `:cursor`
  (grapheme index), `:focusable`, `:placeholder`, `:placeholder_style`,
  `:style`, `:password`. Dumb renderer: the app owns the buffer in its
  model and calls `Harlock.TextBuffer.apply_key/3` in `update/2`. When
  focused, the renderer positions the terminal cursor at the correct
  visual column (wide-grapheme aware).
- `Frame.cursor` (`{row, col} | nil`) plus `Frame.set_cursor/2`. The
  diff renderer wraps each frame with cursor-hide before the body and
  cursor-position + show after, so the terminal cursor only appears
  where a focused widget asks for it.
- `Harlock.Test.cursor/1` — read the current `Frame.cursor` from the
  runtime, useful for asserting text-input positioning in tests.
- `Harlock.Terminal.Termios` — NIF wrapping `tcgetattr` / `tcsetattr` /
  `ioctl(TIOCGWINSZ)` on `/dev/tty`. Replaces the previous `:os.cmd`-based
  termios calls, which never worked: ERTS spawns subprocesses via
  `erl_child_setup` with `setsid()`, detaching them from the controlling
  terminal so `/dev/tty` returns `ENXIO` in the subshell. The NIF runs
  in-process and retains tty access. Dirty I/O scheduler; graceful
  fallback when `/dev/tty` is unavailable (CI, piped stdin).
- C build via `elixir_make` and a small `Makefile` driving
  `c_src/termios.c` → `priv/termios_nif.so`. Cross-compiles on
  macOS (with `-undefined dynamic_lookup`) and Linux.
- End-to-end runtime focus-traversal tests
  (`test/harlock/app/runtime_focus_test.exs`): Tab cycles, Shift-Tab
  reverses, focus_trap inside an overlay confines cycling to the trap,
  trap entry/exit stashes and restores prior focus. The gap of missing
  these tests let the focus_trap bug below ship in earlier v0.2 work.

### Fixed

- `overlay(focus_trap: true)` previously included the *background* child
  in the trap (the entire overlay subtree), so Tab inside a modal could
  leak focus into the underlying widgets and opening a modal would
  sometimes move focus to a background id instead of the foreground.
  The constructor now sets `focus_trap` on the over element directly.
- Reader's spawn-based `:file.read("/dev/tty")` never delivered bytes
  on macOS (verified empirically). Replaced with `enif_select_read` +
  non-blocking `read(2)` through the termios NIF, with the Reader as
  a single GenServer (no spawn child). EOF on the tty (ssh disconnect,
  terminal close) is surfaced as `{:harlock_tty_lost, :eof}` to the
  subscriber and the Reader terminates so the supervisor can tear
  down cleanly. The subscribe-then-arm sequence also kills the prior
  race where bytes arriving before `subscribe/2` were dropped.
- Demo `examples/contacts.exs` Tab focus traversal now actually works.
  (Tab failure was a downstream symptom of the broken spawn-read path,
  not a demo bug.)

### Changed

- The app supervisor gained a `Task.Supervisor` child positioned between
  IO and the runtime (rest_for_one, `:temporary`). It's available when
  the runtime's `handle_continue` dispatches the init-time cmd; a
  runtime exit terminates all in-flight cmd tasks for free; a
  TaskSupervisor crash takes down the runtime cleanly while leaving
  IO alive long enough for the terminal restore on shutdown.
- `Render.Cell.char` now accepts `String.t()` in addition to a codepoint
  integer, so multi-codepoint graphemes (NFD diacritics, ZWJ sequences,
  flag emoji) are stored verbatim rather than NFC-normalized lossily.
- `Render.Frame.write/4` walks `String.graphemes/1` instead of UTF-8
  codepoints. Width-2 graphemes occupy two cells with `:continuation`
  in the second; the diff renderer skips continuations (no bytes emit).
- Renderer's `clip/2`, `align_text/3`, and `draw_title/6` use
  `Harlock.Width` for column math — CJK and emoji content now lays out
  to the correct visual width instead of grapheme count.
- `IO.Test.Writer` mirrors real terminal behavior for wide chars: cursor
  advances by 2, the trailing cell is marked `:continuation`, and the
  reconstructed buffer-to-string output skips continuations.
- Renderer no longer hard-codes `bold: true` for table headers,
  `reverse: true` / `bold: true` for focused rows, `bg: :cyan` for
  selection, or `reverse: true` for the focus-overlay fallback. All of
  these now read from `Harlock.Theme`. The default theme reproduces the
  prior visuals exactly.
- The active-vs-inactive focus distinction in tables (was `reverse` when
  table focused, `bold` otherwise) collapses to a single `:focus` token
  in v0.2. v0.4 may add a separate `:focus_inactive` token if the visual
  loss matters in practice.

## [0.1.0] — 2026-05-12

Initial release. Pure-Elixir TUI framework — TEA-style model/update/view
loop on top of OTP, no NIFs, no ports for the core rendering path.

### Added

- OTP supervision tree: `Keeper → Writer → Reader → Runtime` with
  `rest_for_one` and `max_restarts: 0`. Terminal is restored on any crash
  via `Keeper.terminate/2`.
- TEA loop: `init/1`, `update/2`, `view/1`, optional `subs/1`.
  Dirty-flag rendering, no periodic polling.
- Focus traversal (`Tab` / `Shift-Tab`) with focus traps for modals;
  automatic stash/restore on open/close.
- Constraint layout solver: `:length`, `:percentage`, `:fill` (with
  `:min` / `:max` stubbed as `:length`). Deterministic round-off
  absorption; graceful truncation on over-constraint.
- Cell-grid renderer with frame diffing; ANSI output via `Writer`.
- Elements: `text`, `vbox`, `hbox`, `spacer`, `box` (4 border styles +
  title + padding), `overlay` (5 anchors + focus trap), `table` / `list`
  (row-id identity, single/multi selection, header).
- Input parser handling CSI/SS3, bracketed paste, and XTerm focus
  reporting.
- Headless `IO.Test` backend selectable via `backend: :test` for
  deterministic tests without a TTY.
- Examples: `counter`, `sysmon`.
- Smoke tests driven by `script(1)` (BSD vs util-linux flag handling).

[Unreleased]: https://github.com/thatsme/harlock/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/thatsme/harlock/releases/tag/v0.2.0
[0.1.0]: https://github.com/thatsme/harlock/releases/tag/v0.1.0
