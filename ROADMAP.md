# Harlock Roadmap

A pure-Elixir TUI framework for Unix terminals. TEA-style model/update/view
loop on top of OTP, with a thin termios NIF for direct /dev/tty control.

This roadmap is the working plan through v1.0 (stable API). It's a living
document — revised as the design settles. v0.8.0 is current and published
on Hex.

## Status snapshot (v0.8.0, current)

What works:

- OTP supervision tree (`Keeper → Writer → Reader → TaskSupervisor → Runtime`,
  `rest_for_one`, `max_restarts: 0`, runtime and task supervisor `:transient`).
  Any crash shuts the tree down and `Keeper.terminate/2` restores the terminal —
  including while `Cmd.exec` has handed it to another program. Load-bearing, and
  covered by `priv/crash_smoke.exs` in a real pty.
- `Harlock.run/3` returns `{:ok, reason}` when the app ends itself and
  `{:error, reason}` when it goes down, and leaves the caller's exit trapping as
  it found it.
- TEA loop with `init/1`, `update/2`, `view/1`, optional `subs/1`. Dirty-flag
  rendering, no periodic polling.
- `Cmd` executor for supervised side effects: `Cmd.from/1`, `Cmd.batch/1`,
  `Cmd.map/2`. Results arrive back through `update/2` as messages.
  `Cmd.exec/3` runs another program with the terminal and resumes the app when
  it exits; `Cmd.suspend/0` stops the app for the shell's job control.
- Focus traversal (`Tab` / `Shift-Tab`), focus traps for modals with
  automatic stash/restore on open/close.
- Focus-aware key routing (v0.4): the runtime dispatches navigation keys
  straight to the focused `viewport` / `tabs` / `text_input` / `textarea` /
  `menu` / `select` / `tree` / `table` / `button` / `checkbox` and delivers the
  result as a message, so apps no longer hand-wire `apply_key` helpers.
- Mouse (opt-in, `mouse: true`): clicks focus elements and act on buttons,
  checkboxes, table rows, menu items, tree nodes and markers, tabs, `select`
  choices and `text_input` positions; the wheel scrolls viewports and tables.
  Routed through the same messages as keys, and turned off on every exit. `box(focus_proxy:)` lets a container
  mirror a child's focus for styling without joining traversal.
- Push-shaped subscriptions: `Sub.telemetry` and `Sub.logger` turn `:telemetry`
  events and log calls into `update/2` messages, `Sub.source` subscribes to
  anything that sends to its subscriber (Phoenix.PubSub, registries, `:global`
  groups), plus `sparkline` for trends.
- `table` takes a `fn offset, limit -> rows` window function as well as an
  enumerable, so a query- or stream-backed table is asked only for what fits.
- `Harlock.Bench` measures render and diff cost over five scenarios, reporting
  percentiles. Layout solver covered by property tests as well as examples.
- Constraint layout solver: `:length`, `:percentage`, `:fill`, `:min`, `:max`.
  Deterministic round-off absorption; graceful truncation on over-constraint
  (logs warning, never crashes).
- Cell-grid renderer with frame diffing. ANSI output via `Writer`.
- Theming (v0.4): full token set (`:header`, `:focus`, `:selection`,
  `:border`, `:primary`, `:accent`, `:muted`, `:error`), three built-in themes
  (`:default` / `:dark` / `:high_contrast`), caps-aware colour downgrade
  (truecolor → 256 → 16 → mono), and a table style cascade. `:default`-theme
  output is pinned byte-for-byte against v0.3.0 by a golden-frame test.
- Primitives: `text` (styled runs, `\n`, wrap, align), `vbox`, `hbox`,
  `spacer`, `box` (4 border styles + title + padding), `overlay` (5 anchors + focus trap), `table` / `list`
  (row-id identity, single/multi selection, header), `text_input`, `textarea`
  (multi-line, opt-in word wrap), `viewport`
  (render-then-clip + scroll-into-view + cursor remap), `progress`, `spinner`,
  `statusbar`, `keybar`, `tabs`, `menu`, `select` (dropdown that flips rather
  than clipping near a margin), `tree` (flat projection, id-keyed expansion,
  lazily loaded children), `button` and `checkbox`.
- Undo / redo via `Harlock.UndoStack` — bounded snapshots the app holds in its
  model, with coalescing that breaks on a newline, a cursor jump, or a delete
  after an insert.
- Wide-grapheme width (CJK, emoji, ZWJ sequences, flags).
- Terminal resize reflows: SIGWINCH reaches Keeper through a handler on
  `erl_signal_server`, Keeper reads `ioctl(TIOCGWINSZ)` through the NIF, and the
  runtime clears and redraws at the new size. Checked in a real pty in CI.
- Input parser handles CSI/SS3, bracketed paste, XTerm focus reporting,
  modified arrows (`CSI 1;5A`), Home / End, F-keys, SGR mouse, and the Kitty
  keyboard protocol's encoding.
- `:telemetry` events for frame render, input dispatch, cmd, and reader.
- A headless test backend, started through `Harlock.Test`, for deterministic
  tests without a TTY — with stand-ins for `Cmd.exec` and `Cmd.suspend` and
  synthetic mouse events.
- Examples: `counter`, `sysmon`, `contacts`, `showcase`, `overview`, `notes`,
  `explorer`, `dashboard`, `nodes`.
- Smoke tests in a real pty, run by `scripts/smoke.sh` in CI on Linux and checked
  on macOS: the runtime, focus, resize, `Cmd.exec` (native layer, runtime
  handover, typed input), crash restoration, suspend under a job-control shell,
  mouse reporting on and off, and two examples.
- Packaging and quality gates: Hex package metadata, published hexdocs, CI,
  Dialyzer, and Credo all wired in.

What's stubbed / missing — the honest list:

- `Sub`: `:interval`, `:telemetry`, `:logger` and the generic `:source` exist.
  `file` and `port` are 1.1+ — the seam is built, so they are additions to a
  frozen API rather than design work. `pubsub` is not coming: `source/3` covers
  it.
- No windowed aggregation for metrics (rates, percentiles over a trailing
  window) — 1.1+. Counts and means are a few lines of `Enum` in the model.
- Styled runs are accepted by `text`, `button` and `checkbox`. Box titles, tab
  labels and table cells still take a plain binary.
- **Apps do not work under IEx.** IEx's terminal driver reads the same tty, and a
  Harlock app started from an IEx prompt received no keystrokes when tested.
  Run apps with `mix run`. Several example headers suggest starting them from
  `iex -S mix`, which is wrong and due for correction with the examples.
  The `:ssh` backend (1.1+) avoids the contention altogether.
- Mouse: no drag gestures, no motion without a button held, no double-click —
  until an application needs one.
- Kitty keyboard protocol: parser only — runtime push is deferred.
- No inline (non-alternate-screen) mode, clipboard, or hyperlinks — 1.1+.
- Windows native is unsupported (WSL works); the termios NIF targets POSIX.

## Guiding principles

1. **OTP-first.** The supervision tree is the architecture. New features
   that need processes get their own child, supervised correctly.
2. **No NIFs in the rendering path.** ANSI in, ANSI out. The termios NIF
   shipped in v0.2 is the one allowed exception, strictly scoped to terminal
   control: termios, window size, and handing the terminal to another program,
   with its small `harlock_exec` helper. New native code requires the same
   level of justification.
3. **Phoenix devs feel at home.** `update/view/subs` mirrors LiveView's
   mental model on purpose, and subscribing to a `Phoenix.PubSub` topic is a
   one-liner — via `Sub.source/3` rather than a named `Sub.pubsub`, because
   principle 7 says the dependency belongs in the app rather than here.
4. **Headless-testable.** Every new widget gets coverage under the test
   backend, and every terminal behaviour a smoke test in a real pty. No "works
   on my terminal" features.
5. **Terminal restoration is sacred.** Any new IO path must survive crashes
   without leaving the terminal in raw mode / alt-screen. Test it.
6. **Honest stubs over fake completeness.** Stub modules clearly say so in
   their moduledoc. No silent half-features.
7. **Seams, not adapters.** Harlock provides the shape an integration plugs
   into and stops there. `table` takes a window function, not an
   `Ecto.Queryable`; `Sub.telemetry` takes event names, not an Oban
   dashboard. A terminal UI library should not acquire a dependency on a
   database, a web framework, or a job runner in order to display their
   output — the adapter is a few lines of app code, or its own package if it
   ever earns one. `:telemetry` is the sole first-party integration, and only
   because it is already a dependency and its seam is generic.
8. **Own what only the terminal owner can do.** Priority goes first to what an
   application cannot provide for itself: resize, handing the terminal to another
   program, suspend, terminal modes such as mouse reporting. Something an app can
   build from existing elements in a few lines — a gauge, a chart — can wait.
   Harlock is a foundation in the way curses is, and a gap in the first category
   is a gap no application can close.

## Versioning

- **0.x** — API may break. We document breaking changes in CHANGELOG.
- **1.0** — locked public API. The core is certain: `Harlock`, `Harlock.App`,
  `Harlock.Elements`, `Harlock.Cmd`, `Harlock.Sub`, `Harlock.Render.Style`,
  `Harlock.Layout`, `Harlock.Text`. The rest of what is documented today —
  `Harlock.Test`, `Harlock.Theme`, `Harlock.Focus`, the widget helper modules,
  `Harlock.TextBuffer`, `Harlock.UndoStack`, `Harlock.Width`, `Harlock.Telemetry`,
  `Harlock.Bench`, and `Harlock.Terminal.Termios`, the one terminal module with
  public documentation — is decided module by module in v0.9's freeze pass.
  Internal modules (the runtime, the renderer, the rest of the terminal layer)
  stay `@moduledoc false` and remain free to change without notice.

---

## v0.2-prep — tooling first (do before any v0.2 implementation)

CI gates the v0.2 implementation work; it does not land alongside it.
Otherwise the Cmd executor, SIGWINCH path, and text_input land without
type-checking or lint to catch regressions, and the first green build is
also the first build that has to satisfy every new check at once.

- Add dev deps: `:ex_doc`, `:dialyxir`, `:credo`. Wire `mix docs`.
- `.github/workflows/ci.yml`: `mix format --check-formatted`, `mix test`,
  `mix dialyzer`, `mix credo --strict` on push + PR.
- `.credo.exs` tuned to a green baseline on v0.1 code.
- Dialyzer PLT cached in CI; baseline clean on v0.1 before opening v0.2 PRs.
- `CHANGELOG.md` seeded from v0.1.

---

## v0.2 — "actually usable" (~2 weeks)

The minimum set that lets someone build a real internal tool. Ship together.

### Cmd executor (the unblocker)

The runtime currently destructures `{model, _cmd}` and throws the cmd away.
Wire a real executor.

- Add a Task.Supervisor child to the app supervisor, positioned
  **between IO and Runtime** so it's already up when Runtime's
  `handle_continue` dispatches the init-time cmd. (Earlier plan said
  "after Runtime"; that lost the init-cmd race against the supervisor's
  child-start loop.) Strategy: `:one_for_one`, restart `:temporary` on
  individual tasks.
- Implement `Cmd.from/1`: runs the 0-arity fn under `Task.Supervisor`,
  sends result back as `{:harlock_event, result}`.
- Implement `Cmd.batch/1`: spawns each child cmd concurrently, no
  ordering guarantees.
- Add `Cmd.map/2` for tagging results: `Cmd.map(cmd, fn r -> {:tag, r} end)`.
- Tasks linked to runtime; if runtime exits, tasks die. If a task crashes,
  log + emit `{:harlock_event, {:cmd_error, reason}}` (don't kill runtime).
- Runtime: on `update/2` returning `{model, cmd}`, dispatch cmd, update
  model, render. On `:quit` with cmd, dispatch then quit.

Tests: cmd that sleeps then returns; cmd that crashes; batch of three;
quit-with-cmd ordering.

### SIGWINCH + resize event

Terminal resize must reflow. Without this we can't ship.

- Use `:os.set_signal(:sigwinch, :handle)` (OTP 22+) in `Keeper` (the
  TTY-owning process). Signal arrives as `{:signal, :sigwinch}` in
  Keeper's mailbox.
- Keeper queries new size via `ioctl(TIOCGWINSZ)` through the termios
  NIF (`Harlock.Terminal.Termios.winsize/1`). The original plan
  considered `tput cols`/`tput lines` to avoid native code, but
  `:os.cmd`-based shell-outs lose the controlling tty (every shell
  spawned by ERTS is `setsid()`-detached), so a NIF was needed for
  termios anyway — TIOCGWINSZ goes through the same one.
- Keeper sends `{:harlock_resize, rows, cols}` to Runtime.
- Runtime handles `{:harlock_resize, _, _}`: update `state.rows` /
  `state.cols`, discard `prev_frame` (full redraw — diff against
  differently-sized buffer is meaningless), mark dirty, render.
- Initial size at Runtime startup also comes from `Keeper.size/1`
  (synchronous `GenServer.call`, no race because Keeper starts first
  in the supervision tree). Test backend supplies explicit rows/cols
  via opts.

Tests: simulate resize event into `IO.Test` runtime, assert reflow
(`test/harlock/resize_test.exs`).

**Correction, found in v0.8:** the first bullet was wrong, and the tests could
not show it. `:os.set_signal(:sigwinch, :handle)` delivers the signal to the
`erl_signal_server` event manager, not to the caller's mailbox, so Keeper never
receives `{:signal, :sigwinch}`. The simulated test injects
`{:harlock_resize, …}` below the broken step. See v0.8.

### Wide-grapheme width (prerequisite for text_input)

`String.length` ≠ display columns. Pulled into v0.2 from v0.3 because
text_input cursor math depends on it — shipping text_input first would
either land with broken CJK/emoji handling or force a width retrofit later.
Verified usage at `renderer.ex:188, 194, 200, 308, 315–325` and called out
in code at `renderer.ex:323-324` and `cell.ex:7-8`.

- New module `Harlock.Width`: `width(grapheme)` returns 0/1/2 based on
  Unicode East Asian Width + emoji presentation. Static table — pull from
  Unicode 15.1 EastAsianWidth.txt at build time via `mix harlock.gen_width`.
- Replace `String.length` with `Harlock.Width.string_width/1` in:
  `clip/2`, `align_text/3`, `draw_title/6`, table column rendering,
  and the new `text_input` cursor math.
- Zero-width joiner / variation selectors: keep with the preceding
  grapheme, don't advance the cursor.
- `Cell` stays one codepoint per cell; wide graphemes occupy `cell + cell'`
  where `cell'` is a sentinel "continuation" cell. Frame diffing and clip
  math must skip continuations.

Tests: "héllo" (combining), "東京" (wide), "🇮🇹" (regional indicator pair),
"👨‍👩‍👧" (ZWJ sequence).

### Minimal theme tokens (prerequisite for v0.3 widgets)

Replace the hard-coded styles in the renderer with theme lookups now, so
v0.3 widgets (`progress`, `tabs`, `statusbar`, `keybar`) aren't built
against hard-coded values that need a sweep in v0.4. Full theming
ergonomics still land in v0.4 — this is the minimum surface to avoid
rework.

- `Harlock.Theme` struct with the four tokens the current renderer needs:
  `header`, `focus`, `selection`, `border`. Full token set (`primary`,
  `accent`, `muted`, `error`) deferred to v0.4.
- `Harlock.Theme.get(token)` available in callbacks via process dict
  (same pattern as `Focus`).
- App passes `theme: %Theme{...}` to `Harlock.run/3`; omitted = built-in
  default that matches today's hard-coded values exactly (no v0.1 → v0.2
  visual diff for existing apps).
- Replace hard-coded styles at `renderer.ex:165` (`%Style{bold: true}`
  header), `:211-212` (`%Style{reverse: true}` / `bold: true` focused row),
  `:254` (focus default), `:214, 217` (`bg: :cyan` selection) with theme
  lookups.

Tests: app with custom theme overrides each token; app with no theme
renders byte-identical to v0.1 baseline (golden frame).

### text_input element

Single-line first. The cursor is a new concept — `Frame` needs to track it.

- Add `cursor: {row, col} | nil` to `Frame`. `Writer` emits cursor-show /
  cursor-position after diff, or cursor-hide if nil.
- `text_input` element opts: `:value` (caller-owned, model holds state),
  `:placeholder`, `:focusable` (required), `:on_change` (msg to send),
  `:max_length`, `:style`, `:placeholder_style`, `:password` (mask with `•`).
- Runtime injects key events to the focused `text_input`'s `:on_change`
  with shape `{msg, {:input_event, kind, payload}}` where kind is
  `:insert | :delete | :move | :submit`. App owns the buffer.
- Helper module `Harlock.TextBuffer` (pure functions: `insert/3`,
  `delete_backward/2`, `move_cursor/2`, etc.). App calls it from `update/2`.
  Keeps the element dumb, model honest.
- Keys: printable chars insert, `Backspace` deletes-back, `Delete`
  deletes-forward, `Left`/`Right` move, `Home`/`End` jump, `Enter` submits.

Defer to v0.3: multi-line, IME, word movement (`Ctrl-Left`/`Ctrl-Right`),
selection.

### viewport element

Generic scrollable container.

- `viewport(child: el, height: n, offset: model.offset, on_scroll: msg)`.
- Renders child into a virtual `Frame` of `{requested_w, large_h}`, then
  blits the visible slice into the real region.
- Emits scroll messages on `PgUp`/`PgDn`/`Up`/`Down` when focused.
- App owns the offset (same TEA discipline as text_input).

### Presentation track (parallel with v0.2 implementation)

Tooling itself ships in v0.2-prep (above). What's left here is the
external-facing surface that gates adoption:

- Fill `mix.exs`: `description`, `package` (licenses, links, maintainers),
  `source_url`, `homepage_url`, `docs` config (main: "readme", extras).
- Replace `README.md`: 30-second pitch, screenshot/GIF, install snippet,
  minimum counter example, status table linking to ROADMAP, "why not X"
  (vs Owl, Ratatouille, ratatui-via-port).
- Asciinema cast of `sysmon` embedded in README.

---

## v0.3 — "shows well in demos" (~3 weeks after v0.2)

### Layout: real :min and :max ✓

Shipped. The solver:

1. Computes a lower bound per slot: `:length(n)→n`, `:percentage(p)→p%`,
   `:min(n)→n`, `:fill(_)→0`, `:max(_)→0`.
2. If lower bounds exceed total → truncate from tail and warn (unchanged
   over-constraint behavior).
3. Distributes the remainder across flexible slots. `:fill(weight)`
   carries its weight; `:min` and `:max` each carry weight 1.
4. Clamps `:max` violators to their cap, returns excess to remaining,
   iterates. Convergence is bounded by `length(constraints)` — each
   pass either freezes ≥1 slot or terminates.
5. If `:max` caps leave space unallocated (`[max: 10, max: 10]` in a
   30-cell region), the trailing region is simply not used — children
   don't overflow caps to fill space.

### Standard widgets ✓

Shipped — all composable from existing primitives, dumb renderers with
app-owned state:

- `progress(:value, :max, :width, :style, :fill_style)` — single-line
  bar with `█` for the filled portion.
- `spinner(:tick, :frames, :style)` — single cell. Caller increments
  `:tick` from a `Sub.interval` subscription.
- `tabs(:items, :active, :focusable, :style, :active_style)` —
  horizontal tab bar; the body for the active tab is rendered
  separately by the app. Pair with `Harlock.Tabs.apply_key/3` in
  `update/2` for Left/Right/Home/End navigation.
- `statusbar(:left, :right, :style)` — pinned-row helper, left/right
  alignment with style-filled middle.
- `keybar(:bindings, :style, :separator, :right)` — formats
  `[?q, "quit"]` → `[q] quit`, with arbitrary separators and an
  optional right-aligned addendum.

### Viewport element ✓

Shipped. App-owned scroll state, render-then-clip pipeline:

- `viewport(child:, offset:, content_height:, scrollbar:)` — required
  `:offset` and `:content_height` (app knows what it's scrolling).
- Renderer allocates a `width × content_height` temporary frame,
  renders the child into it, blits the visible slice. Cost is
  O(content × width) per frame — fine for hundreds of rows. Day-one
  perf test (`viewport_perf_test.exs`) holds the budget.
- Scroll-into-view is a render-pipeline phase: focusable elements
  record their bounds via `Frame.set_focus_rect/2`; the viewport
  reads its child's `tall_frame.focus_rect` and snaps the effective
  offset so the focused element stays visible. Model offset is
  untouched — this is render-time-only adjustment.
- Cursor positions (set by `text_input`) are remapped from
  tall-frame coords to dst coords when the cursor falls in the
  visible window; hidden otherwise.
- Optional cosmetic scrollbar: single column on the right edge,
  thumb proportional to `visible_h / content_h`.
- `Harlock.Viewport.apply_key/4` translates scroll keys
  (`:up | :down | :page_up | :page_down | :home | :end`) into a
  new clamped offset. Scroll keys are explicit — app calls the
  helper from `update/2`, no runtime interception. (Superseded by v0.4's
  focus-aware routing, which intercepts them for a focused viewport.)

### Mouse events (parser) ✓

Parser landed. Emits
`{:mouse, action, button | nil, col, row, mods}` for SGR encoding
(`CSI < button;col;row M|m`). Actions: `:press | :release | :drag |
:move | :wheel_up | :wheel_down`. Buttons: `:left | :middle | :right |
:extra4 | :extra5`.

**Runtime enabling + hit-test routing — deferred** (delivered in v0.8, item 5).
At the time the runtime did not write `\e[?1006h` and did not route events to
elements.
Apps that need mouse input can write the enable sequence themselves and
match on raw `(col, row)` in `update/2`. Hit-test infra (frames carry
element bounds, runtime resolves cursor → element) waits on a real use
case shaping the API.

### Modified arrows ✓

`CSI 1;<mod><letter>` for arrows + Home/End with shift/alt/ctrl/meta.
`CSI <n>;<mod>~` for modified PageUp/PageDown/Insert/Delete and F1-F12.

### Kitty keyboard protocol (parser) ✓

Parser landed:

- Detection response `CSI ? <flags> u` → `{:capability,
  :kitty_keyboard, flags}`.
- Key events `CSI <code>[:<shifted>:<base>][;<mod>[:<type>]] u`.
  Event-type 1=press → `{:key, ...}`, 2=repeat → `{:key_repeat, ...}`,
  3=release → `{:key_release, ...}`. Kitty private-range codepoints
  (57344-57375) map to functional-key atoms.

Enabling the protocol (writing `CSI > <flags> u` to push state) is a
runtime decision deferred until a real use case appears.

### Telemetry instrumentation ✓

Shipped. Events:

- `[:harlock, :frame, :render, :start | :stop | :exception]` — span
  wrapping `view/1` + tree walk + diff emission. Stop measurements
  include duration; metadata includes app, dirty, rows, cols.
- `[:harlock, :input, :dispatch, :start | :stop | :exception]` — span
  wrapping the runtime mailbox → `update/2` return path. Metadata
  includes app, event, focused.
- `[:harlock, :cmd, :dispatch]` — one-shot when a cmd is handed to the
  task supervisor. Metadata: `%{kind: :fun | :batch | :map | :none}`.
- `[:harlock, :cmd, :complete]` — when a cmd task returns. Measurements:
  `%{duration: native}`. Metadata: `%{status: :ok | :error}`.
- `[:harlock, :reader, :tty_lost]` — one-shot on EOF (ssh disconnect,
  terminal close).

`Harlock.Telemetry` documents the full catalog. `:telemetry` is a
hard dep (tiny library, no transitive deps).

---

## v0.4 — "absorb the boilerplate" ✓ (shipped 2026-05-18)

The v0.4 plan was re-scoped against [`docs/feedback-v0.3.md`](https://github.com/thatsme/harlock/blob/main/docs/feedback-v0.3.md)
and [`docs/v0.4-plan.md`](https://github.com/thatsme/harlock/blob/main/docs/v0.4-plan.md): instead of growing the widget
roster, v0.4 made the widgets that already shipped cost less to wire.
The original "polish & adoption" sub-sections below are kept as-is for
provenance — entries marked ✓ landed, others moved to v0.5.

### Focus-aware widget key routing (R2) ✓

The headline. Focusable `viewport`, `tabs`, and `text_input` elements
get their navigation keys auto-routed by the runtime; the app's
`update/2` receives a synthesised `{:harlock_scroll | _select | _edit
| _submit, focus_id, payload}` instead of raw `{:key, …}`. Opt out
per-element with `handle_keys: false`. The four routed-message tuples
are public API and documented in `Harlock.App`'s moduledoc.
Applied to `examples/showcase.exs`: the per-field text-input dispatch
clause in `update/2` went 21→7 lines (-67%); the manual
`Viewport.apply_key/4` scroll dispatch went 7→3 lines. No widget calls
`apply_key/_` from `update/2` in showcase any more.

### End-to-end README example ✓

`examples/overview.exs` (also embedded inline in the README between
the Counter snippet and Installation) is a runnable ~70-line app
covering focus traversal, a selectable table, a focusable viewport
with R2 auto-routing, and a `Cmd` round-trip.
`test/examples/overview_test.exs` `Code.require_file`s it so the
README snippet can't rot silently.

### Theming (full token set) ✓

The four-token minimum (`header`, `focus`, `selection`, `border`) landed
in v0.2. v0.4 extends to the full palette and ships the ergonomics around
it:

```elixir
%Theme{
  primary: :cyan,
  accent: :magenta,
  muted: %Style{fg: {:rgb, 128, 128, 128}},
  error: :red,
  border: %Style{fg: :white},
  focus: %Style{reverse: true},
  header: %Style{bold: true},
  selection: %Style{bg: :cyan}
}
```

- Add the remaining tokens (`primary`, `accent`, `muted`, `error`) and
  any per-widget tokens surfaced during v0.3 widget work.
- Built-in themes: `:default`, `:dark`, `:high_contrast`.
- Auto-downgrade truecolor → 256 → 16 based on `Caps`.
- App still configures via `Harlock.run(MyApp, init_arg, theme: theme)`;
  `Harlock.Theme.get/1` already exists from v0.2.

### Style cascade ✓

- `box` propagates `:border_style` to title. ✓ (was already true in
  v0.3 — `draw_title` shares the border style parameter; verified
  during Phase 3.)
- `table` accepts `:header_style`, `:row_style`, `:alt_row_style`,
  `:selected_style`, `:focus_style` (all default to theme). ✓
  `:alt_row_style` is the only behavioural addition; the rest are
  pure overrides that preserve v0.3 output when unset.
- `Style.merge/2` with proper inheritance (child overrides parent;
  unspecified attrs inherit). ✓ (already had these semantics in v0.2;
  verified during Phase 3.)

### `:default` byte-identical to v0.3 ✓

Pinned in `test/harlock/golden_frame_test.exs`. Hash captured by
running the same canonical app under a git worktree at tag `v0.3.0`,
not by observing the v0.4 implementation — so the test proves parity,
not self-locking.

---

## v0.5 — widgets on the new contract ✓ (shipped as v0.5.0)

The work originally listed under v0.4 that was deferred so it could
ship as the **first consumer of the R2 routing contract** instead of
being built against the v0.3 manual-dispatch idiom. Building them
inside v0.4 would have meant writing their key handling against the
old API and rewriting it the moment R2 landed; v0.5 lets them
arrive as native R2 widgets from day one.

That reason is now spent: R2 shipped in v0.4, and `textarea` proved the
contract on the hardest case in v0.4.2–v0.4.3. What remains is a closed
list — `menu`, `select`, `tree`, and the undo helper — and the milestone
closes when those are done. Subscriptions and `box(focus_proxy:)` moved to
v0.6 to keep that boundary meaningful; a widget set has no natural end
otherwise, and this one needs one.

Build order is `menu` → `select` → `tree`: `menu` is the smallest R2
consumer and establishes the pattern, `select` adds the `overlay` open
state on top, and `tree` comes last because it is the only recursive one
and the only one adding a routed tuple to the public contract.

### tree / menu / select widgets

- `tree(:nodes, :expanded, :focused, :on_toggle, :on_select)` —
  recursive node display with expand/collapse on `Right`/`Left` or
  `Enter`. Auto-routed via `{:harlock_select, focus_id, node_id}` and
  a new `{:harlock_toggle, focus_id, node_id}`.
- `menu(:items, :on_select)` — vertical list, arrow navigation,
  `Enter` selects. Auto-routed via `{:harlock_select, focus_id, id}`.
- `select(:items, :value, :on_change)` — dropdown (uses `overlay` for
  the open state). Same routed-select shape.

Each gets its own `apply_key/n` pure helper plus a per-type clause in
the runtime's `route_to_widget/4`; no new mechanism, just three
new consumers.

All three shipped. Two things the plan above did not anticipate, both
worth keeping:

**`select` needed a deferred-draw layer.** `overlay/1` establishes z-order
by holding both layers as children, which a dropdown cannot do — it is
anchored to a control buried in the layout, and every sibling drawn after
that control would bury the panel. So the renderer records floats during
the walk and draws them after it, in push order. That ordering is also the
stack nested panels would need, without anything tracking depth. Placement
flips rather than clips: above the control near the bottom margin,
shifted left near the right one.

**`tree` keeps the tree as data.** `Harlock.Tree.visible/2` projects to the
flat list of visible rows and the renderer draws rows, never recursing.
Rows carry `ancestors_last` — the last-child flag of every ancestor — not
just a depth, because the guides need to know whether each ancestor column
wants a continuation bar or a blank, and only the projection can see
siblings. Expansion is keyed by node id; index keys would move the
selection whenever a node above collapsed.

Lazy children are the interesting part: `:children` is a list or one of
`:unloaded` / `:loading`, so expanding a node over a filesystem or a remote
node is a side effect. The app receives `{:harlock_toggle, …}`, marks the
node loading, returns a `Cmd`, and swaps the result in when it arrives —
which is the clearest demonstration in the widget set of why the model is
not ceremony.

`{:harlock_toggle, focus_id, node_id}` is the only routed message the whole
set added. `menu` and `select` reuse `{:harlock_select, …}` and
`{:harlock_submit, …}`.

### Multi-line text_area ✓ (shipped in v0.4.2)

Shipped as `textarea/1` + `Harlock.TextArea`. Hard and soft line breaks,
vertical motion, display-row Home / End, logical-line kills, and Enter
inserting a newline rather than submitting. Horizontal editing delegates to
`Harlock.TextBuffer`, so both widgets share one key-binding set.

Word wrap is opt-in per element (`wrap: true`) and breaks at word
boundaries, measuring display cells so CJK wraps where it actually reaches
the edge. When wrapping, `↑` / `↓` and Home / End follow display rows;
kills stay logical-line relative, because a wrap boundary isn't in the text.

One deviation from the plan above, deliberate: **the cursor stayed a flat
grapheme index** rather than widening to `{line, col}`. Cross-line motion
then falls out for free — moving left from a line start lands on the
newline ending the previous line, and deleting there joins them — and the
routed-edit message is byte-identical to the one `text_input` produces, so
apps write one clause for both. The visual-vs-logical distinction the plan
anticipated lives in `visual_rows/2` instead of in the cursor type, which
keeps it out of the public message contract.

Goal-column memory landed in v0.4.3. The column is held in runtime state,
keyed by focus and discarded on focus change, so it stays out of the routed
message contract — `apply_key/6` threads it, and vertical motion is the only
thing that pays for computing it.

### Undo / redo as an app-held helper ✓

A textarea without undo is the gap users hit first, and more sharply than in a
single-line input where retyping is cheap. It cannot live in the widget: the
app model owns `:value` and may rewrite it — loading a file, clearing a form,
applying a `Cmd` result — without the widget seeing it, so a buffer-held
history desyncs and starts restoring text the user never typed.

So it ships as a pure helper the app holds in its model and threads
explicitly: bounded snapshots of `{cursor, text}` with coalescing, ring-capped
around 100 entries. Snapshots rather than a command stack — for a buffer this
size they are simpler and fast enough.

Coalescing is the part that has to be right, and it is contract, not
implementation detail. A run of insertions collapses into one step, and the run
**breaks** on a newline, on any cursor jump, and on a delete following an
insert. Get it wrong and a user types a paragraph, presses undo expecting to
lose a word, and loses the paragraph — worse than shipping no undo at all,
because it destroys work rather than merely failing to restore it.

Shipped as `Harlock.UndoStack`, with those three break conditions written into
its moduledoc as contract rather than left as tuning. A cursor jump closes the
run without becoming a step of its own: restoring a caret position while
leaving the text alone would spend an undo press on nothing the user thinks of
as a change. `examples/notes.exs` wires it to `Ctrl-Z` / `Ctrl-R`.

---

## v0.6 — the event-source seam ✓ (shipped as v0.6.0)

Split out of v0.5 so that milestone could close on the widget set alone.
Nothing here is a widget, and holding `tree` / `menu` / `select` back until
`Phoenix.PubSub` integration was also done would have left finished work
unpublished for no reason.

`Sub` then had one kind, `:interval`, which is a *timer* — the runtime
wakes itself up. Everything else worth subscribing to is the opposite shape:
an **external source pushes**, and the runtime has to receive without the
source knowing anything about rendering. That is one seam, and the milestone
is organised around building it once rather than five times.

The ordering below is deliberate. `Sub.telemetry` and `Sub.logger` come first
not because they are the most requested but because they are the same seam
with two genuinely different consumers, which is the only way to find out
whether the abstraction holds before four more callers depend on it.

### Sub.telemetry — the integration that pays for the seam

`:telemetry` is how the entire serious Elixir ecosystem already reports on
itself: Phoenix, Ecto, Oban, Broadway, Finch, Bandit. Integrate with that one
thing and a Harlock app gets an ops UI for all of them. Attaching
`[:ecto, :repo, :query]` and `[:oban, :job, :stop]` should be a working
dashboard in about twenty lines.

    Sub.telemetry([:ecto, :repo, :query], &{:query, &1.query_time})

Three constraints that shape the design rather than decorate it:

- **Handlers execute in the emitting process.** The handler must do the
  minimum — build a message and send it — or it slows down the very system it
  is measuring. All aggregation happens on the runtime side.
- **Handlers are global.** They must detach when the app stops, or a restarted
  app leaks a handler that sends to a dead pid.
- **Attach a named module function, not a closure.** `:telemetry` warns about
  anonymous handlers for real performance reasons; Harlock's own test suite
  prints that warning today, which is the mistake to avoid making publicly.

Needs a **windowed aggregator** — counts, rates, and percentiles over a
trailing window — because raw events are useless in a table and something has
to hold that state between frames.

### Sub.logger — the same seam, proving it generalises

A `:logger` handler that forwards log events into `update/2`, giving a log
viewer with level filtering and metadata search. Small, and it is the demo
that needs no explanation.

It exists in this milestone mainly as the second consumer. If the seam built
for telemetry also carries logging without special-casing, it will carry
`pubsub` and `port` too. If it does not, better to learn that here than after
the fourth caller.

Same detach-on-shutdown requirement, same do-not-block rule: a handler that
blocks slows every log call in the system.

### sparkline ✓

A one-line trend widget, because a numeric column is not a dashboard and a
`progress` bar shows a fraction rather than a history. Takes a list of numbers
and draws them with block glyphs, auto-scaled. Needed by the telemetry work
above rather than desirable alongside it.

Shipped with the glyph ramp as an explicit `:glyphs` option rather than
switching on capabilities: the internal caps struct tracks colour depth,
bracketed paste, mouse and kitty, and has no notion of glyph coverage. Adding
one would mean guessing — a mono terminal renders block elements perfectly
well, so colour depth is not a proxy for it. Passing an ASCII ramp explicitly
is honest and follows `spinner`'s `:frames`.

### The remaining Sub kinds — moved to v0.7

v0.6.0 shipped without `pubsub`, `file`, `signal` and `port`. The milestone's
point was the seam, and the seam is done and proven against two deliberately
different consumers, so holding a finished release for four additions that need
no design work would have been holding it for nothing.

They are listed under v0.7 rather than becoming a v0.6.x series: each adds a
public function to `Harlock.Sub`, and additive-in-a-patch is the tension this
project already hit in v0.4.2. They sit alongside the hardening work rather than
displacing it — that work is what v1.0 waits on, and it should not keep sliding
to make room for small features.

### `box(focus_proxy: :child_id)` ✓

Polish for the R2 visual story. With R2 default-on, `:focusable`
lives on the interactive widget (the viewport, the tabs, the text
input) — but the wrapping `box` is what users *see*. The
`focus_proxy:` opt lets a box mirror a named child's focus state for
visual highlighting only (border style, title style) without itself
participating in focus traversal.

Shipped in the shared focus-styling path rather than as a box special case, so
any element taking focus styling honours it. Not participating in traversal
needed no work: focusable collection keys on `:focusable`, so a proxy is
invisible to Tab by construction rather than by being filtered out afterwards.

`examples/overview.exs` has dropped the `border_style/1` helper it used as a
stand-in — a workaround referenced from its own comment, this section, and the
v0.4 R2 review.

---

## v0.7 — measurement, data access, and the generic seam ✓ (shipped as v0.7.0)

Not the milestone originally planned under this number. What shipped is the work
that turned out to be ready: a benchmark harness, the textarea speedup it
justified, windowed table rows, `Sub.source/3`, and property tests for the
layout solver.

Three of those five changed a plan rather than executing one. The benchmark
rescoped incremental rewrap *downwards*; measuring the table showed windowing was
never a rendering optimisation; and `Sub.source/3` deleted `Sub.pubsub` from the
roadmap instead of implementing it.

### Harlock.Bench ✓

`Harlock.Bench` measures render and diff over five
canonical scenarios, reporting percentiles rather than a mean because a frame
budget is about the slow frames. Public rather than dev-only, so app authors
can measure their own views.

First baseline, 200×80, 100 samples, one dev machine — useful for comparison
against itself, not as an absolute:

| scenario | p50 | p99 |
|---|---|---|
| `text_rows` | 3 481µs | 4 403µs |
| `nested_boxes` | 8 499µs | 10 035µs |
| `table_rows` | 11 878µs | 12 697µs |
| `tree_expanded` | 12 083µs | 13 312µs |
| `textarea_wrapped` | 19 148µs | 22 425µs |

Three things this establishes, all of which were assumptions before:

**A wrapped textarea missed a 60 Hz budget**, before the memo below. ~16 700µs per frame is
the target and p50 is 19 148µs. Scaling confirms the cause is rewrapping the
whole value: n=50 → 4 198µs, n=200 → 20 275µs, n=800 → 56 115µs, roughly
linear in content. That was the number the textarea work had to beat, rather than a suspicion.

**An unchanged frame is not free.** Diffing two identical 200×80 frames costs
3 072µs at p50 — comparable to rendering `text_rows` outright, because the
comparison walks all 16 000 cells with no early-out. The dirty-flag runtime
only diffs when something changed, so this is not currently a live cost, but
it caps how cheap a redraw can ever be.

**The layout solver is not the bottleneck.** 24 levels of nested boxes cost
less than half a wrapped textarea, which redirects optimisation effort away
from where it might otherwise have gone first.

### Textarea wrap memoisation ✓

Rescoped by what the benchmark
actually showed, and smaller than it looked.

A single render called `visual_rows/2` three times over: directly, then again
inside `visual_position/3`, then again inside `scroll_to_reveal/5`. Removing
that repetition needed no invalidation logic at all — `visual_rows/2` keeps a
one-entry memo keyed by the value and width themselves, so a hit requires the
key to match and there is nothing to get stale. Editing replaces the binary,
the next call misses, and that is correct.

| n paragraphs | redraw unchanged | while editing |
|---|---|---|
| 50 | 2 457µs | 3 686µs |
| 200 | 5 734µs | 10 444µs |
| 800 | 6 656µs | 21 196µs |

Against the pre-memo 19 148µs at n=200, that is 1.8x on the editing path and
3.3x on redrawing unchanged content. n=200 now fits a 60 Hz budget; n=800 does
not.

**What remains is bounded by profiling, not guesswork.** At n=200 wrapping is
2 457µs of a 10 444µs render — 24% — and the rest is cell writing, which is
bounded by region size rather than content. So a line-break index with
per-line invalidation can only take a quarter off a mid-sized document. Its
value grows with size, though, because wrapping scales with content while
drawing does not: at n=800 wrapping is closer to half the cost. That makes it
worth doing for large documents and not worth doing for typical ones — which
is the opposite of the priority it had before it was measured.

### Windowed `table` rows ✓

`:rows` accepts a
`fn offset, limit -> rows` function as well as an enumerable, with `:offset`
app-owned because keyset pagination has no row index to auto-centre on.

The benchmark corrected the reason for doing it. Render cost is flat in row
count already — 10 137µs at 200 rows, 8 908µs at 20 000 — because drawing is
bounded by the region, and the `length/1` / `find_index/2` / `drop/2`
traversals the list path performs are trivial beside cell writing. So this was
never a rendering optimisation.

What it actually buys is not *acquiring* rows nobody will see. A list-backed
table over a query issues a query for every row; a windowed one asks for
viewport-many. The benchmark could not show that because it pre-built an
in-memory list, which is exactly the kind of measurement that confirms the
wrong thing.

No `Ecto.Queryable` adapter, deliberately — see the principle below. A
query-backed table is a few lines of app code over the window function, and
building it in-tree would put a database dependency inside a terminal UI
library.

### `Sub.source/3` ✓

Subscribe to anything that delivers Erlang messages; the subscribe function runs
inside the subscription's own process. It removed `Sub.pubsub` from the plan —
see guiding principle 7.

### Layout solver property tests ✓

Twelve properties for the layout solver over
generated constraint lists: sizes non-negative, one rect per constraint, slots
contiguous and non-overlapping, cross axis untouched, `:max` never exceeded,
`:length` honoured with slack absorbed, `:fill` proportional to weights,
over-constraint truncating rather than crashing, zero regions yielding zero
slots, and determinism.

One of them was wrong before the solver was: "a split always consumes the whole
region" fails for `[{:max, 0}]`, because filling the space would violate the cap
the caller asked for. The solver is right and the invariant needed the
condition, which is the sort of correction generated input produces and example
tests do not.

Running at StreamData's default 100 runs per property. Worth raising if the
solver changes.

---

## v0.8 — the missing basics ✓ (shipped as v0.8.0)

An earlier version of this section declared v0.8 closed to features, on the
argument that every feature added before 1.0 is another shape frozen
permanently. That argument still holds for *additive* work, and the `Sub` kinds
and metrics helper stay in 1.1+ because of it.

It did not survive an audit of what the library cannot do. A terminal UI library
that cannot style a word inside a sentence, hand the terminal to `$EDITOR`, or
notice the window being resized is not ready to freeze. So the basics came first
and shipped as v0.8.0; the freeze prep that was the second half of this
milestone follows as v0.9.

### The missing basics

In order. Two tests decide whether an item belongs here rather than in 1.1+:
whether it changes a contract 1.0 would lock, and whether an application could
provide it itself (principle 8). Each item says which applies.

1. **Terminal resize never reached the runtime** ✓ — a defect, not a feature.
   `Keeper` called `:os.set_signal(:sigwinch, :handle)` and waited for
   `{:signal, :sigwinch}`, but OTP delivers handled signals to the
   `erl_signal_server` event manager, never to the caller. Every resize test
   injected `{:harlock_resize, …}` directly, below the broken step.

   Fixed with a `:gen_event` handler on `erl_signal_server` that only forwards to
   Keeper, supervised by Keeper so it cannot outlive it. Teardown no longer resets
   the signal to `:default`, which would cut off every other handler, OTP's
   `prim_tty_sighandler` included. The fix exposed a second bug the first had
   hidden: the redraw after a resize assumed a blank screen and left the old
   frame's borders behind.

   `priv/resize_smoke.exs` resizes its own pty and checks the runtime follows, in
   CI. This also unblocks `Sub.signal` (1.1+), which needs the same mechanism.

2. **Styled and wrapped text** ✓ in `text`, and in `button` and `checkbox`
   labels; box titles, tab labels and table cells later. `text/2` took one binary, one style, one line, and clipped it.
   There was no way to bold one word or colour a value inside a sentence, and
   `"\n"` was silently dropped. `tabs`, `keybar` and `statusbar` each draw mixed
   styles with private code, so the library already needed styled runs and
   rebuilt them per widget.

   Changes a contract: what `text` accepts. The shape chosen, over a separate
   `paragraph` element:

   ```elixir
   text("plain, as before")
   text(["CPU ", {"92%", fg: :red, bold: true}, " of 8 cores"])
   text(description, wrap: true, align: :center)
   ```

   - A run is a binary or `{binary, style}`, where style is anything `:style`
     already accepts. A run's style merges over the element's style and focus
     style.
   - A binary `content` keeps the existing render path, so its output stays
     byte-identical — the golden-frame test holds that — and `Harlock.Bench`'s
     `text_rows` must not regress.
   - `"\n"` is always a line break.
   - `wrap: true` reuses `textarea`'s word wrap. A run keeps its style across a
     wrap. Text taller than its region is clipped at the bottom.
   - `align: :left | :center | :right`, per line.
   - `Harlock.Text.height(content, width)` is public. `viewport` takes an
     app-supplied content height, and an app cannot know the height of wrapped
     text without measuring it; without this, wrapped text cannot scroll.

   A separate element was rejected because it would not avoid designing the run
   type — box titles, tab labels and table cells will want styled text too — and
   because a binary inside `text` keeps its fast path anyway. Accepting runs in
   those other places is a later, additive step.

3. **Button and checkbox** ✓ — `button/2` and `checkbox/2`. Additive, so not a
   freeze requirement, but wanted before 1.0: they are small, a settings screen is the first thing a newcomer
   builds, and a 1.0 without them reads as incomplete. After item 2, because a
   label is a natural first consumer of styled runs.

   Most of the need was already met, which kept this small. `text` with
   `:focusable` already got focus styling; what was missing was routing, so an
   app checked `Focus.current()` in an `{:key, :enter, []}` clause. Enter or Space
   now arrive as `{:harlock_submit, id}` and `{:harlock_toggle, id, checked}` —
   no new message shapes.

   A radio group was left off the list, on the grounds that `select` and `menu`
   already cover choosing one of several, and a checkbox *group* was left as
   `table` with `selection: {:multi, set}`, lacking only Space-to-toggle
   routing. Both calls were reversed in v0.9 — see the showcase entry under
   "Build one real application first".

4. **Handing the terminal to another program, and suspend** ✓ — `Cmd.exec/3`
   and `Cmd.suspend/0`. Opening `$EDITOR`
   on a file, running a pager, or `git commit` needs the terminal released
   (leave alternate screen, restore termios, stop the reader) and reclaimed
   afterwards with a full redraw. Ctrl-Z is the same sequence around a stop.

   Additive to the public API — `Cmd.exec/3` and `Cmd.suspend/0` are new
   functions — but here by principle 8: an application cannot do this itself.
   Every program the BEAM starts, through `:os.cmd` or a port, runs in a new
   session with no controlling terminal. Opening `/dev/tty` fails in it, and
   Ctrl-C, Ctrl-Z and SIGWINCH go to the BEAM instead. Redirecting its stdin to
   the tty by path makes stdin a tty but changes none of that.

   **Approach, verified by a spike on macOS and Linux:** start the program from
   the termios NIF with `posix_spawn` into its own process group, with fds 0–2 on
   the tty and signal dispositions reset, then make that group the terminal's
   foreground with `tcsetpgrp`, as a shell does. In a real pty the child could
   open `/dev/tty` itself, received Ctrl-C (the BEAM did not) and SIGWINCH, and
   vim edited and wrote a file; the BEAM took the foreground back each time.

   Three requirements the spike showed are not optional:

   - **SIGTTOU blocked while reclaiming the foreground.** Once the child exits the
     BEAM is a background group, and `tcsetpgrp` from there stops the BEAM
     outright under a job-control shell (and fails with `EIO` in an orphaned
     group). OTP cannot handle SIGTTOU, so the NIF blocks it in the calling thread.
   - **A way to get the exit status.** The BEAM ignores SIGCHLD, so the kernel
     discards a child's status at exit and `waitpid` never returns it — the first
     spike hung there. The spike defaulted SIGCHLD for the child's lifetime, which
     is a VM-wide change. What shipped instead is a small helper,
     `priv/harlock_exec`, that waits for the program and reports its status,
     leaving the VM's disposition alone.
   - **A child stopped by Ctrl-Z.** A program that does not handle SIGTSTP stops,
     and there is no job table to return to. v0.8.0 resumed it in the
     foreground; since the editor example showed that surprises people, it is
     reported instead, and with a job-control shell the app stops with it (see
     v0.9).

   While the program runs, `update/2` keeps processing subscriptions and `Cmd`
   results but nothing is drawn, and one full redraw follows. A second exec while
   one is running is refused. A crash while the terminal is handed over restores
   it, reclaims the foreground, and kills the child's process group;
   `priv/crash_smoke.exs` checks that in a real pty.

   `Cmd.suspend/0` is opt-in, not bound to Ctrl-Z by the runtime:
   `examples/notes.exs` and the `Harlock.UndoStack` docs already use Ctrl-Z for
   undo. In the spike, SIGTSTP stopped the BEAM, SIGCONT arrived through the
   `erl_signal_server` handler from item 1, and terminal modes were intact on
   resume.

   **Not under IEx.** In the spike, a program started under IEx never received
   its input, and IEx's own IO then terminated; after a SIGCONT, OTP's tty handler
   reset the terminal to cooked mode. The cause is not specific to this item: a
   plain Harlock app under IEx received no keystrokes in the same test, because
   IEx's terminal driver reads the tty too. See the IEx entry in the status list.

5. **Mouse** ✓ — moved from 1.1+; phases 1 and 2. Additive, but here by
   principle 8, twice over: turning reporting on and guaranteeing it is turned
   off on every exit path belongs to whoever owns the terminal, and only the
   renderer knows where an element landed, so an app cannot work out what was
   clicked.

   - **Opt-in**, `Harlock.run(app, arg, mouse: true)`: while reporting is on,
     the terminal's own drag-to-select needs a modifier. Modes 1000, 1002 and
     1006; 1003 (motion with no button) is left off.
   - **Off on every way out**: the disable sequence is part of the terminal's
     leave sequence, which quitting, crashing, `Cmd.exec` and `Cmd.suspend` all
     write.
     `priv/mouse_smoke.exs` records the pty's output and checks the order of
     on and off for quit, crash and an exec round trip.
   - **Routed like keys**, no new message shapes: the renderer records each
     focusable element's rectangle (the renderer's hit-region recorder), overlays and
     floats record occluders, a viewport translates and clips what it scrolls.
     Phase 1: a left press focuses and presses buttons and checkboxes; the wheel
     scrolls a viewport three lines or moves a table a row. Everything else is
     the raw event.
   - **Phase 2** ✓: clicks on the items inside widgets. The renderer records
     each visible item as a part of its element's region — table rows, menu
     items, tree nodes and their expand markers, tabs, an open `select`'s
     choices — and a `text_input` click maps the column to a grapheme. A menu
     click selects and activates; a tree marker toggles while the row selects.
   - **Only if an application needs it**: drag gestures, motion with no button
     held, double-click.

---

## v0.9 — freeze prep (next, and the last milestone before 1.0)

The second half of what v0.8 was planned to be. Nothing in this milestone adds a
feature: it is the work that decides what 1.0 commits to. The freeze decisions
depend on the shapes v0.8 settled and on what building a real application on
them turns up.

### Build one real application first

The highest-value item here, and the one most likely to be skipped.

`table`'s window function and `Sub.source/3` have no real-world use yet, and
neither do most of v0.8's basics, and 1.0 commits to their shape permanently. Something substantial has to be
built on this API before it is frozen — the node/distribution explorer is the
obvious candidate, since `tree` with lazy children already fits a supervision
tree and `Sub.telemetry` can feed it live numbers.

The evidence for insisting: every single time a real consumer touched this code,
it found something the tests did not. `examples/notes.exs` exposed that
Alt-Backspace could not be delivered at all. `examples/explorer.exs` exposed a
filter that left directories looking like leaves. `examples/dashboard.exs`
exposed a log pane that was permanently empty and a sparkline showing timer
jitter. Three for three. Freezing an API that no application has exercised
would be the one avoidable mistake left.

**`examples/nodes.exs` is the first pass at this** — a BEAM node explorer with a
windowed process table, a lazily loaded supervision tree, and memory sampled on
a timer. It found two things, both now decisions rather than surprises:

1. **`table`'s window function is called during rendering.** Fine for a list,
   ETS, or `Process.info/2`; not fine for a query or a remote node, because
   rendering would block on IO. Now documented on `table/1`. Whether that is the
   right shape to freeze is a genuine question — the alternative is an async
   fetch protocol, which is considerably more API.
2. **`table` had no auto-routing** — fixed. Every scrollable table used to
   hand-write the six key clauses `viewport` gets for free; `nodes.exs` had them
   verbatim and `overview.exs` had a `Focus.current()` dispatch plus three
   clauses of index arithmetic. Both are gone.

   Which state the arrows move depends on the rows source, because the two modes
   have different things to move: enumerable rows move `:focused_row` and deliver
   `{:harlock_select, …}`; a window function moves `:offset` and delivers
   `{:harlock_scroll, …}`. No new message shape, and no new public function
   beyond `Harlock.Table`'s two pure helpers.

   The awkward part was the end of the data. A window function is never asked for
   a total, so there is no maximum offset to clamp against, and `:down` at the
   bottom would otherwise scroll into empty space forever. A fetch returning
   fewer rows than requested is the only end signal available, so the renderer
   records it and routing refuses to advance past it. `:end` stays a noop for the
   same reason.

   This was a behaviour change, not a pure addition: a focusable table now
   consumes navigation keys that previously reached `update/2`. Opt out with
   `handle_keys: false`.

`nodes.exs` predates v0.8's basics. Reworking the examples onto them is the
current pass of this item, and every awkward spot it finds is recorded here as a
question for the freeze rather than worked around quietly.

**`examples/editor.exs`** — a file list, a preview, `Cmd.exec` on `$VISUAL` /
`$EDITOR` / `vi`, `Cmd.suspend`, the mouse, styled status lines. It found three
things:

1. **An app is never told the terminal's size.** Resize is handled entirely
   inside the runtime; `update/2` receives no event and `view/1` no dimensions.
   That makes wrapped text in a `viewport` impossible to size: `viewport` takes
   `:content_height` from the app, and `Harlock.Text.height/2` needs the pane's
   width, which only the renderer knows. The editor shows its preview unwrapped
   because of it. Two shapes would close it, not mutually exclusive: a
   `viewport(content_height: :auto)` that measures its child at the width it
   lays out, or a size message delivered to `update/2` on start and on every
   resize. The first keeps apps free of layout arithmetic; the second is what an
   app laying out by breakpoints would want anyway.
2. **`table` has no message for Enter.** `menu` and `tree` deliver
   `{:harlock_submit, id}` on Enter; `table` routes only the arrows, so "open
   the selected row" needs a raw `{:key, :enter, []}` clause guarded by
   `Focus.current()`. A routed `{:harlock_submit, id}` on Enter would be
   additive and consistent with the other list widgets.
3. **Ctrl-Z inside a program started by `Cmd.exec` did nothing** ✓. The helper
   resumed a stopped program, since there is no job table to hand it to — so
   Ctrl-Z in vim neither suspended vim nor returned to the shell. Now the helper
   reports the stop, and with a job-control shell above the app, the app stops
   too: the shell shows the job suspended, and `fg` resumes the app and then the
   program. Without such a shell the program is resumed in place.
   `priv/exec_stop_smoke.exs` checks it as a job under bash; it was also
   checked with vim under zsh.

**`examples/contacts.exs`**, reworked — Add / Edit / Delete buttons, a
dialog with a favourite checkbox and Save / Cancel buttons, styled detail
labels, pane borders through `focus_proxy`, the mouse throughout. It found two
defects and two questions:

1. **An `overlay` let the background show through its blank cells** ✓. The
   panel was drawn over the background without clearing its region, so a
   dialog's empty rows showed the text beneath — in `contacts` the details
   pane, in `sysmon` the process table behind the help panel. Now the region is
   cleared first.
2. **`Focus.current/0` in `view/1` reported the focus from before the frame**
   ✓. Focus is settled from the tree `view/1` returns, so a view that shows the
   focus — a status line, a highlighted border — was one frame behind whenever
   focus moved without a key: `nil` on the first frame, and the old id when a
   dialog opened or closed. The runtime now runs `view/1` once more when
   settling moved the focus.
3. **Table cells are plain strings.** A column's `:render` returns a binary,
   so the favourite marker in the list cannot be coloured the way the same
   marker is in the details pane. Accepting styled runs, as `text/2`, `button/2`
   and `checkbox/2` do, would be additive; whether per-cell styles belong in
   `table` at 1.0 or next to `:row_style` later is the question. The Enter
   question above came up again: Enter on the list opens the dialog through
   the same raw-key clause.
4. **`focus_proxy` names one id.** A box with `focus_proxy` lights its border
   while that widget has focus and, with the mouse, takes clicks for it. The
   details pane holds three buttons, so it can do neither: its border stays
   dark while one of them has focus, and a click on its blank space focuses
   nothing. Accepting a list — lit while any is focused, a click focusing the
   first — would be additive and covers any pane of several controls, a form
   or a button bar. Left as it is in the example until the freeze decides.

**`examples/explorer.exs`**, reworked — the mouse on the tree, the filter and
the actions; the right column split into Filter and Actions panes so each
border follows its widget; a details pane and a status line in styled text. It
found one gap, closed with a new message:

1. **An app was never told that focus moved** ✓. The filter's `open` state
   belongs to the app, as `Harlock.Select` documents, but Tab and clicks move
   focus inside the runtime. An open dropdown stayed drawn after focus left
   it — over the Actions menu, which then moved an invisible highlight on Down
   — and no clause could close it, since a click on a pane's border produces
   no message at all. Now every move is delivered as
   `{:harlock_focus, from, to}`: the first focus, Tab, a click (before the
   click's own messages), a trap opening or closing, the focused element
   leaving the view. This is a new message shape in the 1.0 vocabulary, the
   first since routing, and it is the general form of what the dropdown
   needed: any state that only holds while something has focus — an edit to
   commit when a field is left, a search mode — closes on it. The alternatives
   were drawing the list closed from `Focus.current/0` in `view/1`, which
   leaves the model saying open, or moving `open` into the widget, which
   reverses a documented decision and helps no other widget.

**`examples/showcase.exs`**, reworked — a clickable tab bar, log lines with
styled levels and services, a pause button and a loop checkbox on the Widgets
tab, and raw mouse events in the Keys tab. It found two questions and one gap:

1. **An app cannot move focus.** Focus starts on the first focusable element in
   tree order and moves only by Tab, clicks and traps. Making the tab bar
   focusable, so a click switches tabs, put it first — so the log no longer
   scrolls on the arrows at startup, and switching to the Keys tab leaves focus
   on the tab bar, where Left and Right switch tabs instead of being captured.
   The example asks for a Tab into the log or the event list. Contacts wanted
   the same after saving: focus on the new contact's row, not back where the
   dialog was opened. A way to ask for focus — a `Cmd`, or an option naming
   the initial focus — would be additive; which shape, and whether a request
   from `update/2` should win over a trap, is the question. The keyboard-only
   alternative, `handle_keys: false` on the tab bar, is not one: it turns off
   the click routing too, since both go through the same element.
2. **The wheel does not reach an enclosing viewport.** Over the Form tab the
   wheel lands on a `text_input`, which does not scroll, and the event goes to
   `update/2` raw; the viewport around the fields is never asked. A viewport
   scrolls on the wheel only when it is itself the element under the pointer
   and focusable. Passing an unhandled wheel up to the nearest scrollable
   ancestor would make every long form scroll; the viewport has no focus id to
   report the offset under, which is the part to decide.
3. **The basic input widgets were not all there** ✓. A tour of the widgets had
   no radio group, no check list and no list box to show, and those are what a
   settings or order form is made of in any terminal UI library. v0.8 had ruled
   the radio group out because `select` and `menu` cover choosing one of
   several; that holds for the choice but not for the screen, where the options
   are meant to be seen side by side and chosen with one key or click. Now:
   - `radio_group/1`, with `Harlock.RadioGroup` — the arrows move the choice
     itself, vertically or side by side, and a click chooses;
     `{:harlock_select, id, value}`.
   - A check list: Space on a focused `table` or `list` with
     `selection: {:multi, set}` delivers `{:harlock_toggle, id, row_id}`, and
     `list/2` with `marker: :checkbox` draws `[x]` / `[ ]` and toggles on a
     click.
   - A list box is `list/2` as it was, now documented as one.

   No new message shapes: the radio group sends what `tabs` sends, and the
   check list sends what `tree` sends. A fifth showcase tab, Inputs, puts them
   in an order form with a checkbox, a `textarea` — which the tour had also
   left out — and Save / Reset buttons.

**`examples/dashboard.exs`**, reworked — a radio group for the workload, Pause and
Clear buttons, a scrollable log history with coloured levels, styled stats. Every
widget it needed was already there, but running it found a defect no test had:

1. **Log output drew over the app** ✓. The console logger writes to the same
   terminal, and nothing muted it, so every `Logger` call — the example logs
   every few jobs — landed mid-frame and stayed. Muting alone would lose the
   runtime's own report of a render crash, so the console handlers are muted
   and mirrored for the session, and the last 500 events are printed after the
   terminal is restored. No option for it yet; printing live or dropping
   instead are possible additions if an app needs them.

**`examples/nodes.exs`**, reworked — clickable tabs, the wheel on the process
list, a click on a process showing its details, styled header and system
stats. It found one question:

1. **A windowed table cannot be moved through row by row from the keyboard.**
   With a window function the arrows move `:offset`, by design, since there is
   no row set to walk — so the only way to choose a process is a click, and a
   keyboard user cannot pick one at all. `focused_row` does style a row inside
   the window, so moving it within the visible rows and scrolling at the edges
   is possible without knowing the total; the question is whether that belongs
   in the routing, at the cost of a second meaning for the arrows. The tab bar
   taking the first focus came up again too: see "An app cannot move focus".

Still wanted before the freeze: an application built by someone other than the
author of the framework, which is the only test of whether the docs say enough.

### Freeze decisions to make explicitly

Two calls that should be made in the audit rather than by default:

- **`Harlock.Bench`** is public as of v0.7.0, which was right for letting app
  authors measure their own views. "Public" and "frozen at 1.0" are different
  commitments, though, and freezing a benchmark harness's shape is a poor
  trade. Either exclude it from the freeze explicitly, or move it behind
  `@moduledoc false` and keep it dev-facing.
- **The caps struct** is `@moduledoc false` today, and the caps-refinement item
  below says to document it as public. That is a freeze decision, not a
  documentation task: making it public means committing to its fields. Decide
  which, deliberately.

### Hardening

- **Dialyzer clean** at `:underspecs` + `:overspecs`. Strict specs on all
  public functions.
- **Property-based tests for frame diffing.** The layout solver has them (see
  v0.7); "replaying the diff produces an equivalent frame" does not yet. It needs
  the diff's ANSI interpreted back into cells, and the test backend's writer
  already does that for the subset the renderer emits — cursor moves, clears and
  style codes. Whether that subset is enough for the property, or a stricter
  interpreter is needed, is the open question.
- **Incremental rewrap for `textarea`** — the part the memo did not cover (see
  v0.7): a line-break index with per-line invalidation, worth it for large
  documents only.
- **Documentation**: every public function has `@doc` + example. Module
  guides (`guides/getting_started.md`, `guides/widgets.md`,
  `guides/testing.md`, `guides/embedding.md`).
- **Examples expansion**: filemgr (two-pane), todo (text_input + list),
  log_viewer (viewport + filter), git_branch_picker (tree).
- **Caps refinement**: detect terminfo entries properly; fallback table for
  common terminals. Whether the caps struct becomes public is a freeze decision
  — see above — not a side effect of documenting it. The low-capability path
  matters more than it looks: a serial console often reports no `TERM` at all,
  which is also the Nerves case.
- **Public API freeze candidate**: walk every `@moduledoc false`, decide
  stable-public vs internal-forever. Move stable parts to `@moduledoc`
  proper.

## v1.0 — stable API

- Public API frozen per the `@moduledoc` decisions above.
- v0.8's missing basics landed and v0.9's freeze prep complete, including at
  least one real application built on the API.
- Announcement post + Reddit/Elixir Forum thread.
- Minimum supported: Elixir 1.19+, OTP 26+ — matching the `elixir: "~> 1.19"`
  requirement `mix.exs` already ships. CI tests OTP 28 only, so the OTP floor
  needs a CI job before 1.0 claims it.

---

## 1.1+ — additive, deliberately after the freeze

None of this breaks anything, which is why none of it belongs before 1.0. Each
item is a new capability that a minor release can add to a frozen API without
touching what is already there. Holding 1.0 for any of them would mean freezing
a larger surface later in exchange for nothing.

### The rest of the Sub kinds

Each follows the seam v0.6 established — a linked process owning the
registration, a handler that only builds and sends, teardown on the way out.
No new design work.

- `Sub.file(path, opts)` — watch via `:fs` if available, polling fallback.
  First-party rather than a `source/3` one-liner because the polling fallback
  and change detection are real logic.
- `Sub.port(cmd, args)` — long-running external process, stdout lines as events.
  Also real logic: port lifecycle, partial-line buffering, exit handling.
- `Sub.signal(:sigusr1, msg)` — **unblocked by v0.8 item 1.** The verification
  this waited on is done, and `Keeper`'s comment was wrong: handled signals go
  to the global `erl_signal_server` event manager, not to the caller, and
  SIGWINCH reflow was not working at all. Keeper now forwards through a
  `:gen_event` handler, and an app-level signal sub would be a second consumer of
  the same mechanism. It must not reset a signal to `:default` on teardown while another
  consumer — Keeper, or OTP's own `prim_tty_sighandler` — still depends on it.

`Sub.pubsub` is **not** on this list. `Sub.source/3` covers it, and a named
constructor would add a `phoenix_pubsub` dependency to a terminal UI library in
order to receive messages the seam already handles.

Relative order should follow whichever real application needs one first. That is
the mistake the original list made: `Sub.pubsub` led it because it was written
first, not because anything needed it — and it turned out not to be needed at
all.

### Windowed aggregation for metrics

Rates and percentiles over a trailing window, for `Sub.telemetry` consumers.
Scoped *down* by `examples/dashboard.exs`: counts, mean, min and max over a
bounded list are three lines of `Enum` in the model with nothing worth
abstracting. A helper earns its place only for what needs time — per-second
rates, and percentiles that cannot be derived from a running total.

### Deferred terminal capabilities

- **Kitty keyboard protocol push.** Parser only. Needed for chords the legacy
  encoding cannot express, and not for Alt-modified letters, which already work.
- **`:ssh` backend.** An IO seam addition rather than a redesign: the backend
  seam already exists and the test backend proves a non-tty backend fits. It
  also sidesteps the `user_drv` contention problem entirely, since an SSH
  channel is not the controlling terminal. This is the prerequisite for Nerves
  over SSH, where the console is an Erlang shell rather than a pty.
- **Inline mode.** Render into a region of the normal screen instead of the
  alternate screen, the shape prompts, pickers and progress displays in CLI
  tools use. A run option rather than a new contract, but the Writer and the
  restore path both assume the alternate screen today, and scrollback
  interaction needs design.
- **Clipboard via OSC 52.** Copy from an app, including over SSH where no
  local clipboard API exists. A `Cmd`; support is terminal-dependent, so it
  needs a caps entry.
- **Hyperlinks via OSC 8.** A style attribute on a run, so it follows v0.8's
  styled text rather than preceding it.

### More widgets

Additive, and each should arrive with the real application that needs it rather
than speculatively.

- Bar chart and gauge, beside `sparkline`.
- Horizontal scrolling for `viewport`, deliberately left out when it shipped
  vertical-only.
- Resizable split panes, which want mouse drag from v0.8 item 5.

---

## Out of scope (probably forever)

- Windows native console. The TTY layer is POSIX-only and that's fine.
  WSL works.
- Rendering anything other than monospace cells. No Sixel, no Kitty
  graphics protocol, no images. Different project.
- Web export. Different project.

## Stretch / "would be cool"

- **`Harlock.LiveView`** — a Phoenix LiveView hook that renders the same
  element tree to HTML for remote viewing. Same model, two backends.
  Probably v1.x.
- **Hot reload** of the app module during dev. Possible because TEA is
  pure — re-invoke `view/1` after code change. Needs careful supervisor
  handling.
- **Recording / replay** — log every event + final frame, replay
  deterministically for bug reports. Useful for headless testing too.

## Architecture notes

- The runtime is the spine. Every field in its state is load-bearing for the
  focus, render and subscription lifecycle, so features that need process state
  usually get their own GenServer rather than a runtime field.
- The renderer is pure: an element tree in, a frame out, no I/O.
- Every IO path has a crash-path test. `priv/crash_smoke.exs` is the template —
  crash the app on a real pty, assert the terminal is restored. It exists because
  the earlier argument for clean teardown was never tested, and was wrong: see
  the next note.
- The comment block in the app supervisor carries the correctness argument for
  clean teardown: `rest_for_one`, a `:transient` runtime, and Keeper as the
  first child. The runtime
  was `:temporary` until a crash test showed that a temporary child's crash
  shuts nothing down, leaving the terminal raw.
