# Changelog

All notable changes to Harlock will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While on `0.x`, the public API may break between minor versions. Breaking
changes are called out in the relevant release notes.

## [Unreleased]

### Added

- **`textarea/1` — a multi-line text area**, backed by the new
  `Harlock.TextArea`. Hard line breaks, vertical motion, line-relative Home /
  End, and Enter inserting a newline instead of submitting. Horizontal editing
  delegates to `Harlock.TextBuffer`, so both widgets share one implementation
  and one set of key bindings.

  The cursor is a flat grapheme index rather than a `{line, column}` pair —
  the roadmap anticipated widening the type, but keeping it flat makes
  cross-line motion fall out for free (moving left from a line start lands on
  the newline ending the previous line; deleting there joins them) and lets
  the runtime deliver textarea edits through the *same*
  `{:harlock_edit, id, {value, cursor}}` message a `text_input` produces. Apps
  write one `update/2` clause for either widget.

  `Ctrl-k` and `Ctrl-u` are line-relative here, unlike their `TextBuffer`
  counterparts which act on the whole value; `Ctrl-k` at end-of-line kills the
  newline and joins, matching emacs `kill-line`.

  Not yet implemented: word wrap (long lines clip) and goal-column memory
  (vertical motion clamps the column to the target line rather than restoring
  the original on the next long line). Both are noted in `ROADMAP.md`.

- **`Harlock.TextBuffer.push_kill/2`** — pushes killed text onto a ring,
  dropping empty kills and applying the depth cap. Exposed so `TextArea` can
  build line-relative kills on the same ring policy rather than duplicating it.

- **Readline-style editing in `Harlock.TextBuffer`.** Word motions
  (`move_word_left/2`, `move_word_right/2`), kills that return the removed
  text (`kill_word_backward/2`, `kill_word_forward/2`, `kill_to_end/2`,
  `kill_to_bol/2`), and `yank/3`. A word is a run of alphanumeric graphemes;
  everything else separates. All of it operates on grapheme indices, so CJK
  and combining sequences behave.

  `apply_key/3` gains the bindings these imply: `Alt-b` / `Alt-f` and
  `Ctrl-←` / `Ctrl-→` for word motion, `Ctrl-a` / `Ctrl-e` for line motion,
  `Ctrl-w` / `Alt-d` / `Ctrl-k` / `Ctrl-u` for kills, `Ctrl-d` for delete
  forward. Every one of these already arrives through the legacy parser — no
  kitty keyboard protocol needed.

- **`Harlock.TextBuffer.apply_key/4`** threads a kill ring so `Ctrl-y` works,
  returning `{:edit, value, cursor, kill_ring}`. The ring is capped at 16
  entries and a kill that removes nothing leaves it untouched. `apply_key/3`
  is unchanged in shape and threads an empty ring, so R2 auto-routing keeps
  the existing `{:harlock_edit, id, {value, cursor}}` contract exactly.
  Undo/redo is deliberately not included: the app model owns `:value` and can
  rewrite it without this module seeing it, so a buffer-held history would
  silently desync.

### Changed

- **A focused `text_input` now consumes the editing keys above.** Previously
  any `ctrl`- or `alt`-modified character was `:noop` and fell through to
  `update/2`; an app binding `Ctrl-k` globally will no longer see it while an
  input has focus. Set `handle_keys: false` on the element to keep them. Keys
  that leave value and cursor unchanged still fall through, so `Ctrl-a` on an
  empty input reaches `update/2` as before.

- **The termios NIF build is now skipped on hosts that can't support it** —
  `:win32`, or any host with `HARLOCK_SKIP_NIF=1`. `mix.exs` selects the
  `:elixir_make` compiler through `Harlock.MixProject.skip_nif?/0` instead of
  running it unconditionally. `Harlock.Terminal.Termios` already degraded to a
  logged warning when the NIF was absent, so the skip surfaces as "terminal
  control unavailable" rather than a compile failure. This makes the
  pure-Elixir majority of the library — renderer, layout, widgets, parser, and
  the `:test` backend — compile and test on a host without a C toolchain.

  `test_helper.exs` probes whether the NIF actually loaded and excludes
  `[:nif]`-tagged tests when it hasn't. Where the NIF *was* expected to build,
  a missing NIF raises instead of quietly dropping coverage, so a broken
  toolchain on CI can't turn into a green run.

- Telemetry duration assertions accept `0`. Durations are `:native` units from
  `:telemetry.span/3`, and a host with a coarse monotonic clock legitimately
  reports `0` when work finishes inside one tick — asserting `> 0` tested the
  host clock rather than the measurement.

### Fixed

- **Added `.gitattributes` with `* text=auto eol=lf`.** With `core.autocrlf`
  and no attributes file, a Windows checkout left CRLF in the working tree
  while the repo stored LF. Git hid the difference, but tools reading files
  directly did not: `mix credo --strict` reported 29 "windows line endings"
  issues locally on a commit that passed CI. Binary assets are marked so they
  are never touched.

- The README's `examples/overview.exs` link used a relative path. `examples/`
  is not an ex_doc extra, so while the link worked on GitHub it resolved to a
  missing page on hexdocs.pm — a 404 on the end-to-end example that v0.4.0
  added specifically to answer the top new-user question. It is now a full
  GitHub URL, matching the convention `ROADMAP.md` already uses for its
  `docs/` references.

### Changed (docs only — no API or runtime change)

- `ROADMAP.md`'s intro and status snapshot still described v0.1. They listed
  the `Cmd` executor as "the single biggest hole", reported `text_input`,
  `viewport`, `tabs` and the rest of the widget set as absent, claimed `:min`
  and `:max` behaved as `:length` (contradicting the v0.3 section of the same
  file), and stated that `mix.exs` had no package metadata and that CI,
  Dialyzer, and Credo were unwired. All of that shipped across v0.2–v0.4.
  Because `ROADMAP.md` ships in the hex tarball and renders as a hexdocs
  extra, the published v0.4.1 docs described a four-release-old library as an
  unfinished skeleton. The snapshot now reflects v0.4.1.
- The v1.0 milestone no longer lists "Hex publish, hexdocs.pm live" as a
  deliverable — that has been true since v0.2.0 — and its heading drops the
  now-inaccurate "Hex release".
- README showcase screenshot references the `v0.4.1` tag instead of `v0.4.0`.
- The v1.0 minimum-supported target moves to Elixir 1.19+ / OTP 26+, resolving
  a contradiction: the roadmap named Elixir 1.17+ as a still-open question
  while every Hex release since v0.2.0 has shipped `elixir: "~> 1.19"`, which
  already makes 1.17 and 1.18 uninstallable.

## [0.4.1] — 2026-05-18

Patch release. One test-stability bug that affects downstream
consumers running their suites against Harlock on CI, plus a small
typespec + docs cleanup that gets the v0.4.x hexdocs build to zero
warnings. No runtime behaviour change for end users; no API
additions or removals.

### Fixed

- The `:test` backend now uses deterministic truecolor caps instead of
  consulting host `$TERM`, so tests that render through
  `Harlock.Test.start_app/3` produce identical bytes regardless of
  where they run. Previously: `$TERM` unset (GitHub Actions runners)
  or `dumb` → caps classified as `:mono` → `Style.to_sgr/1` stripped
  every color SGR → test assertions on color output (golden frame,
  table style cascade) failed in CI while passing locally. The
  `:terminal` backend still detects host caps and downgrades for
  genuinely color-poor terminals — that's the feature; only the test
  backend was wrong to inherit it. New `Caps.test_defaults/0` exposes
  the synthetic struct for explicit use.

### Changed (internal / docs only — no public API change)

- `Harlock.Render.Style.downgrade/2` typespec uses a local
  `Style.depth` type (`:mono | :ansi16 | :ansi256 | :truecolor`)
  instead of the hidden `Caps.color_depth/0`. Functionally identical;
  hexdocs.pm can now resolve the type reference.
- CHANGELOG, ROADMAP, and `Style` moduledoc dropped link-form
  references to `@moduledoc false` modules so the docs build is
  warning-free. The information stayed; the auto-link targets didn't
  resolve before and silently 404'd on hexdocs.pm.
- ROADMAP `docs/feedback-v0.3.md` and `docs/v0.4-plan.md` references
  switched to full GitHub URLs so the links resolve from hexdocs.pm
  (those files are dev-facing and intentionally not in the hex
  tarball).

## [0.4.0] — 2026-05-18

The "absorb the boilerplate" release. v0.3 shipped a complete widget
set; v0.4's job was to stop making app authors hand-wire every key
press through `apply_key` helpers. The runtime now routes navigation
keys directly to focused widgets, the theme grows beyond the four
renderer-only tokens it had, and `:default`-theme rendered output is
verified byte-for-byte against v0.3.0 by a pinned golden-frame test.
There is one breaking change to how key events reach `update/2` — see
Changed.

### Added

- **Theme: full token set, built-in themes, caps-aware color
  downgrade.** `%Harlock.Theme{}` picks up four general-purpose
  tokens — `:primary`, `:accent`, `:muted`, `:error` — alongside the
  four v0.2 renderer tokens. Three built-in themes ship via
  `Harlock.Theme.builtin/1`: `:default` (byte-identical to v0.3),
  `:dark`, and `:high_contrast`. `Harlock.Render.Style.to_sgr/1`
  now consults the internal terminal-capabilities layer and downgrades
  RGB and 256-color values to whatever the terminal can display
  (truecolor → 6×6×6 cube → nearest of the 16 standard ANSI colors →
  `:default` on mono). When no caps are installed the path defaults to
  truecolor, preserving v0.3 emission exactly. The capabilities module
  gains `__set__`/`__clear__`/`get`/`color_depth` helpers mirroring the
  Focus/Theme process-dict pattern; the runtime sets caps before each
  render and dispatch.

- **Table style cascade.** The `table/1` element accepts five new
  style opts: `:header_style`, `:row_style`, `:alt_row_style`,
  `:selected_style`, `:focus_style`. Each defaults to its current
  resolution (`header_style` → `Theme.get(:header)`, selection / focus
  via the existing tokens, plain rows to `%Style{}`), so existing
  apps render unchanged. `:alt_row_style` is the only behavioural
  addition — when set, odd-indexed visible rows pick it up for zebra
  striping; the default `nil` keeps v0.3 single-style row output.

- **Golden-frame test** (`test/harlock/golden_frame_test.exs`). A
  small canonical app exercising every theme-driven render path is
  rendered under `Theme.default()`; the raw byte stream is hashed and
  pinned in-tree. The pinned hash was independently captured by
  running the same app under a git worktree at tag `v0.3.0`, so the
  test proves byte-for-byte parity with v0.3 rather than just locking
  Phase 3's output to itself. Future changes that silently alter
  default output fail CI with a message instructing how to
  intentionally re-pin if the drift is wanted.

- **Focus-aware widget key routing (R2).** A focused widget that
  carries a `:focusable` id and whose type is one of `:viewport`,
  `:tabs`, or `:text_input` no longer needs the app's `update/2` to
  receive raw `{:key, …}` events and re-dispatch through the
  widget's `apply_key` helper. The runtime calls the helper itself
  (`Harlock.Viewport.apply_key/4`, `Harlock.Tabs.apply_key/3`,
  `Harlock.TextBuffer.apply_key/3`) and delivers the result as one
  of four well-known routed-message tuples:
  - `{:harlock_scroll, focus_id, new_offset}` — focused `viewport`
  - `{:harlock_select, focus_id, new_id}` — focused `tabs`
  - `{:harlock_edit, focus_id, {new_value, new_cursor}}` — focused `text_input`
  - `{:harlock_submit, focus_id}` — focused `text_input` saw Enter

  The four tuples are documented as public-API contract in
  `Harlock.App`'s moduledoc. No-op operations (e.g. `:up` on a viewport
  already at offset 0, `:left` on a text input at cursor 0) fall
  through to `update/2` as raw `{:key, …}` events so apps can still
  react. Opt out per-element with `handle_keys: false`.

  Applied on `examples/showcase.exs` (the most key-handling-heavy
  example in the repo), measured against the v0.3 manual-dispatch
  baseline:

  - **Form text-input clause** (Phase 4a, no user-visible change):
    21 → 7 lines, **-67%** on that clause. Removed the
    `Focus.current()` → `TextBuffer.apply_key/3` → reassemble
    `model.form.{values,cursors}` ladder; one
    `{:harlock_edit, {:form_field, field}, {v, c}}` clause replaces
    it. `alias Harlock.TextBuffer` no longer needed.
  - **Logs viewport scroll clause** (Phase 4b, with a keybind
    change): 7-line `when key in [...]` guard + helper call → 3-line
    `{:harlock_scroll, :logs_viewport, n}` clause. The
    `log_visible_height/0` helper and `alias Harlock.Viewport`
    dropped out. Tab now goes to runtime focus traversal, so the
    Logs tab's alert-row cycling moved from `Tab`/`Shift-Tab` to
    `]`/`[`; legend and keybar labels updated.

  Across both clauses, the `apply_key`-wiring share of `update/2`
  fell from 29 lines (21 form + 7 logs + 1 helper) to 13 lines
  (7 + 6), **-55% overall**. No `apply_key` helper is called from
  showcase's `update/2` anymore; the file is the worked example
  the four routed-message tuples in `Harlock.App`'s moduledoc
  point at.

- `examples/overview.exs` — runnable end-to-end example covering focus
  traversal, a focusable table with row selection, a focusable viewport
  with R2 auto-routing, and a `Cmd` round-trip. The same app body is
  embedded in `README.md`, and `test/examples/overview_test.exs`
  `Code.require_file`s the example so the README snippet can't rot
  silently in CI.

### Changed

- **BREAKING: R2 default-on auto-routing changes how navigation keys
  reach `update/2`.** If you have a `viewport`, `tabs`, or `text_input`
  widget that carries a `:focusable` id and your `update/2` binds the
  keys that widget handles (`:up`/`:down`/`:page_up`/`:page_down`/
  `:home`/`:end` for viewport; `:left`/`:right`/`:home`/`:end` for
  tabs; printables/arrows/backspace/delete/enter for text_input),
  **those key clauses in your `update/2` will silently stop firing
  the moment that widget is focused** — the routed
  `{:harlock_scroll | _select | _edit | _submit, focus_id, _}`
  message arrives instead. See the Event vocabulary section of
  `Harlock.App`'s moduledoc for the four shapes, or set
  `handle_keys: false` on the element to keep the v0.3 manual-handling
  path. This is the single migration step every existing app must
  consider; everything else is additive.
- Boundary cases (e.g. `:up` on a viewport already at offset 0,
  `:left` on a text input at cursor 0) fall through to `update/2` as
  raw `{:key, …}` events so apps that bind those gestures for
  out-of-widget actions (focus-out, menu open) still work.
- Tab / Shift-Tab were always consumed by the runtime when any
  focusable existed in the tree; v0.4 documents this explicitly in
  `Harlock.App`'s moduledoc. Apps that bound Tab for sub-navigation
  should rebind to another key when adding focusable widgets — the
  binding will be silently shadowed otherwise. (Worked example:
  `examples/showcase.exs` rebound Logs-tab alert cycling from Tab to
  `]`/`[` in this release.)
- The internal `Focusables.collect/1` traversal now returns
  `{ids, traps, routed_widgets}` instead of `{ids, traps}`. The third
  element is the focus-id-to-element map the runtime uses for R2
  dispatch. Internal API (`@moduledoc false`); affects only callers
  that pattern-matched on the previous 2-tuple shape.

## [0.3.0] — 2026-05-13

Demo-quality release. Adds the viewport, the standard widget set
(progress / spinner / statusbar / keybar / tabs), real `:min` / `:max`
layout constraints, telemetry instrumentation, and parser support for
SGR mouse events, modified arrows, and the kitty keyboard protocol.

### Added

- **Viewport element.** `viewport(child:, offset:, content_height:,
  scrollbar:)` renders a child taller than its allocated region and
  blits the visible slice. App owns the offset (same TEA discipline as
  `text_input`). Render pipeline:
  - Allocates a `width × content_height` temporary frame, renders the
    child into it, blits the window. Cost is O(content × width) per
    frame — fine for hundreds of rows. A pull-based windowed source
    for 10k-row content is a v0.5 candidate.
  - Scroll-into-view is a render-pipeline phase: focusable elements
    record their bounds via `Frame.set_focus_rect/2`; the viewport
    snaps the effective offset so the focused element stays visible.
    Model offset is untouched (render-time adjustment only).
  - Cursor positions set by `text_input` are remapped from tall-frame
    coords to dst coords when the cursor falls in the visible window;
    hidden otherwise. Focused inputs inside a scrolled viewport
    position the terminal cursor correctly.
  - Optional cosmetic scrollbar via `:scrollbar` opt — single column
    on the right edge, thumb proportional to `visible_h / content_h`.
- `Harlock.Viewport.apply_key/4` — pure helper translating
  `:up | :down | :page_up | :page_down | :home | :end` into a new
  clamped offset. `:page_up` / `:page_down` move `viewport_h - 1`
  rows to preserve one row of context. Other keys return offset
  unchanged.
- Real `:min` and `:max` layout constraints. `{:min, n}` reserves at
  least `n` cells and grows like a fill (weight 1) if there's room.
  `{:max, n}` behaves like a fill (weight 1) capped at `n` — excess
  from a hit cap redistributes to other flexible slots until the
  solver converges. If `:max` caps leave space unallocated
  (e.g. `[max: 10, max: 10]` in a 30-cell region), the trailing
  region is unused rather than overflowing.
- Standard widgets — composable from existing primitives, dumb
  renderers with app-owned state:
  - `progress(value:, max:, width:, style:, fill_style:)` — single-
    line bar, integer cell fill.
  - `spinner(tick:, frames:, style:)` — single cell, frame cycled by
    the caller's tick counter (typically driven by `Sub.interval`).
  - `statusbar(left:, right:, style:)` — pinned-row helper with left
    / right alignment and middle padding.
  - `keybar(bindings:, separator:, right:, style:)` — formats
    `[k] label  [k] label` from a list of `{key, label}` tuples.
  - `tabs(items:, active:, focusable:, style:, active_style:,
    separator:)` — single-line tab bar; active tab gets
    `Theme.get(:focus)` when the widget is focused,
    `Theme.get(:header)` when not.
- `Harlock.Tabs.apply_key/3` — pure helper mapping
  `:left | :right | :home | :end` to `{:select, id} | :noop`,
  mirroring the `TextBuffer` pattern.
- **Mouse event parser.** SGR encoding only
  (`CSI < button;col;row M|m`). Emits
  `{:mouse, action, button | nil, col, row, mods}`. Actions:
  `:press | :release | :drag | :move | :wheel_up | :wheel_down`.
  Buttons: `:left | :middle | :right | :extra4 | :extra5`. Runtime
  enabling (writing `\e[?1006h`) and hit-test routing are deferred
  — apps that need mouse input can write the enable sequence
  themselves and match on raw `(col, row)` in `update/2`.
- **Modified arrow / navigation keys.** `CSI 1;<mod><letter>` for
  arrows + Home/End, `CSI <n>;<mod>~` for PageUp/PageDown/Insert/
  Delete and F1-F12. Modifier set is `:shift | :alt | :ctrl | :meta`
  in any combination — encoded as the XTerm modifier byte minus 1,
  with each bit mapped to one modifier.
- **Kitty keyboard protocol parser.** Capability detection response
  `CSI ? <flags> u` emits `{:capability, :kitty_keyboard, flags}`.
  Key events `CSI <code>[:<shifted>:<base>][;<mod>[:<type>]] u`
  with event-type 1 (press) → `{:key, ...}`, 2 (repeat) →
  `{:key_repeat, ...}`, 3 (release) → `{:key_release, ...}`. Kitty
  private-range codepoints (57344-57375) map to functional-key
  atoms. Enabling the protocol (writing `CSI > <flags> u`) is
  deferred.
- `:telemetry` instrumentation. Hard dep on `:telemetry ~> 1.2`
  (tiny, no transitive deps). Events:
  - `[:harlock, :frame, :render, :start | :stop | :exception]` —
    span wrapping `view/1` + tree traversal + diff emission.
    Metadata: `app`, `dirty`, `rows`, `cols`.
  - `[:harlock, :input, :dispatch, :start | :stop | :exception]` —
    span wrapping keystroke → `update/2` return. Metadata: `app`,
    `event`, `focused`.
  - `[:harlock, :cmd, :dispatch]` — one-shot when a cmd is handed
    to the task supervisor. Metadata:
    `%{kind: :fun | :batch | :map | :none}`.
  - `[:harlock, :cmd, :complete]` — when a cmd task returns.
    Measurements: `%{duration: native}`. Metadata:
    `%{status: :ok | :error}`.
  - `[:harlock, :reader, :tty_lost]` — one-shot on EOF (ssh
    disconnect, terminal close).

  See `Harlock.Telemetry` for the full catalog.
- `examples/showcase.exs` — four-tab tour of v0.3: 200-row
  scrollable log viewer with viewport + scrollbar, a long form using
  scroll-into-view, a widget gallery with animated
  progress/spinner/statusbar/keybar, and a key-event inspector for
  modified arrows.

### Changed

- `:min` / `:max` constraints now solve distinctly from `:length`.
  In v0.2 these atoms were documented to "behave as `:length`"; code
  written against that stub behavior will produce different layouts
  in v0.3. Replace `{:min, n}` with `{:length, n}` if you wanted the
  v0.2 behavior. `:length`, `:percentage`, and `:fill` are unchanged.

### Removed

- The v0.2 `validate_constraints!` guard that raised on `:min`/`:max`
  — those constraints now work.

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

[Unreleased]: https://github.com/thatsme/harlock/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/thatsme/harlock/releases/tag/v0.4.1
[0.4.0]: https://github.com/thatsme/harlock/releases/tag/v0.4.0
[0.3.0]: https://github.com/thatsme/harlock/releases/tag/v0.3.0
[0.2.0]: https://github.com/thatsme/harlock/releases/tag/v0.2.0
[0.1.0]: https://github.com/thatsme/harlock/releases/tag/v0.1.0
