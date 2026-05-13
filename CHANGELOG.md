# Changelog

All notable changes to Harlock will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While on `0.x`, the public API may break between minor versions. Breaking
changes are called out in the relevant release notes.

## [Unreleased]

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

- SIGWINCH-driven terminal resize. `Keeper` installs an `:os.set_signal`
  handler in init/1; on signal it shells out to `stty size` and forwards
  `{:harlock_resize, rows, cols}` to the runtime, which discards
  `prev_frame` (full redraw at the new size) and re-renders. The handler
  is removed on Keeper terminate so it doesn't leak past process death.
- `Tty.size/0` — query the terminal dimensions via `stty size` (single
  shell-out, ~3–5ms).
- `Harlock.Test.resize/3` — synthetic resize event for headless tests.
  Resizes the test writer's cell buffer in lockstep so the next frame
  has somewhere to land.
- `Harlock.Width` — display-column width for terminal rendering. Handles
  East Asian Wide / Fullwidth, emoji, regional-indicator flag pairs,
  combining marks, ZWJ, and variation selectors. Public surface:
  `width/1`, `string_width/1`, `slice/2`, `pad_trailing/3`,
  `pad_leading/3`. Ranges sourced from Unicode 15.1 EastAsianWidth.txt.

### Changed

- `App.Supervisor` gained a `Task.Supervisor` child positioned between
  IO and Runtime (rest_for_one, `:temporary`). It's available when
  Runtime's `handle_continue` dispatches the init-time cmd; a Runtime
  exit terminates all in-flight cmd tasks for free; a TaskSupervisor
  crash takes down Runtime cleanly while leaving IO alive long enough
  for the terminal restore on shutdown.
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

[Unreleased]: https://github.com/thatsme/harlock/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/thatsme/harlock/releases/tag/v0.1.0
