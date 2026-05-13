# Harlock Roadmap

A pure-Elixir TUI framework for Unix terminals. TEA-style model/update/view
loop on top of OTP, no NIFs, no ports for the core rendering path.

This roadmap is the working plan from v0.1 (current) to v1.0 (Hex-publishable,
stable API). It's a living document — revise as we learn.

## Status snapshot (v0.1, current)

What works:

- OTP supervision tree (`Keeper → Writer → Reader → Runtime`, `rest_for_one`,
  `max_restarts: 0`). Terminal is restored on any crash via
  `Keeper.terminate/2`. This is correct and load-bearing — don't regress it.
- TEA loop with `init/1`, `update/2`, `view/1`, optional `subs/1`. Dirty-flag
  rendering, no periodic polling.
- Focus traversal (`Tab` / `Shift-Tab`), focus traps for modals with
  automatic stash/restore on open/close.
- Constraint layout solver: `:length`, `:percentage`, `:fill`. Deterministic
  round-off absorption; graceful truncation on over-constraint (logs warning,
  never crashes).
- Cell-grid renderer with frame diffing. ANSI output via `Writer`.
- Primitives: `text`, `vbox`, `hbox`, `spacer`, `box` (4 border styles +
  title + padding), `overlay` (5 anchors + focus trap), `table` / `list`
  (row-id identity, single/multi selection, header).
- Input parser handles CSI/SS3, bracketed paste, XTerm focus reporting.
- Headless `IO.Test` backend selectable via `backend: :test` for
  deterministic tests without a TTY.
- Examples: `counter`, `sysmon`. Smoke tests driven by `script(1)` (handles
  BSD vs util-linux flag differences).

What's stubbed / missing — the honest list:

- `Cmd` executor: runtime ignores the `{model, cmd}` return tuple entirely.
  No async work, no IO, no HTTP. **The single biggest hole.**
- `Sub`: only `:interval` exists.
- Layout: `:min` and `:max` constraints behave as `:length` (documented).
- No SIGWINCH handling — terminal resize doesn't reflow.
- No `text_input`, `viewport`, `progress`, `spinner`, `tabs`, `tree`,
  `menu`/`select`, `keybar`/`statusbar`.
- No mouse, no kitty keyboard protocol, no modified arrows (`CSI 1;5A`).
- No wide-grapheme width (CJK, emoji). `String.length` ≠ visual columns.
- `Style` not consistently cascaded (table headers hard-code `bold`,
  focused box hard-codes `reverse`).
- No `row.ex` helper (only `column.ex`).
- `mix.exs` has no package metadata. README is the `mix new` default.
- No CI, no Dialyzer, no Credo wired in.

## Guiding principles

1. **OTP-first.** The supervision tree is the architecture. New features
   that need processes get their own child, supervised correctly.
2. **No NIFs in the core.** ANSI in, ANSI out. NIFs only if a NIF-optional
   path measurably ships (e.g. termios via port).
3. **Phoenix devs feel at home.** `update/view/subs` mirrors LiveView's
   mental model on purpose. `Sub.pubsub` should be a first-class citizen.
4. **Headless-testable.** Every new widget gets `IO.Test`-driven coverage.
   No "works on my terminal" features.
5. **Terminal restoration is sacred.** Any new IO path must survive crashes
   without leaving the terminal in raw mode / alt-screen. Test it.
6. **Honest stubs over fake completeness.** Stub modules clearly say so in
   their moduledoc. No silent half-features.

## Versioning

- **0.x** — API may break. We document breaking changes in CHANGELOG.
- **1.0** — locked public API for `Harlock`, `Harlock.App`, `Harlock.Elements`,
  `Harlock.Cmd`, `Harlock.Sub`, `Harlock.Render.Style`, `Harlock.Layout`.
  Internal modules — Harlock.App.Runtime, the rest of Harlock.Terminal.\*,
  Harlock.Element.Renderer — stay `@moduledoc false` and remain free
  to change without notice.

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

### Layout: real :min and :max

Two-pass solver:

1. Sum all `:min` and `:length`. If > total, behave as today (truncate
   from tail, warn).
2. Distribute remainder across `:fill` constraints proportional to weight.
3. Apply `:max` caps: any fill exceeding its `:max` gets clamped, the
   excess redistributed to non-capped fills. Iterate to fixpoint
   (max 3 passes, bail with warning otherwise).

Tests: percentage + min + fill + max combinations; over-constraint;
unsatisfiable max.

### Standard widgets

All composable from existing primitives; ship as named modules for
ergonomics and consistency.

- `progress(:value, :max, :width, :style, :fill_style)` — single-line bar.
- `spinner(:frames, :interval, :style)` — uses `Sub.interval` internally.
  Caller passes a model field for the tick counter (TEA discipline).
- `tabs(:items, :active, :on_select, :focusable)` — horizontal bar +
  region underneath, focus integrates with traversal.
- `statusbar(:left, :right, :style)` — pinned-bottom helper, often paired
  with `vbox` and `{:length, 1}`.
- `keybar(:bindings, :style)` — `[{?q, "quit"}, {?n, "new"}]` → rendered
  `[q] quit  [n] new`.

### Mouse events

SGR mouse mode `\e[?1006h` on init, `\e[?1006l` on teardown (via Caps +
Writer).

- Parser emits `{:mouse, action, {row, col}, mods}` where action is
  `:press | :release | :drag | :wheel_up | :wheel_down` and button is
  `:left | :middle | :right` for press/release/drag.
- Runtime does a hit-test against the last `Frame` (frames carry
  element-id metadata for hit-testable cells — new infra) and routes to
  the right element.
- Defer global mouse-down dragging across regions to v0.4.

### Modified arrows + kitty keyboard protocol

- `CSI 1;<mod><letter>` for `Ctrl/Alt/Shift + arrows/home/end`.
- Detect kitty support via `\e[?u` query at startup, set protocol level if
  supported. Falls back to legacy parsing otherwise.
- Emit unified `{:key, key, mods}` events regardless of source protocol.

### Telemetry instrumentation

Emit `:telemetry` events from the runtime so apps can wire Prometheus /
Grafana / Loki dashboards for the things that matter operationally:

- `[:harlock, :frame, :render]` — duration in µs, dimensions, dirty
  status. Catches render-time regressions and per-terminal weirdness.
- `[:harlock, :cmd, :dispatch]` / `[:harlock, :cmd, :complete]` —
  cmd execution time, success / `:cmd_error` rate.
- `[:harlock, :input, :dispatch]` — event arrival → `update/2` return
  duration. Surfaces input lag separately from render lag.
- `[:harlock, :reader, :tty_lost]` — single-fire when EOF on the tty.

~50 LOC of instrumentation, optional `:telemetry` dep with
`runtime: false` defaults to no-op handlers. Turns "weird flicker on
xterm-256color" from anecdote into a chart.

---

## v0.4 — "polish & adoption" (~4 weeks)

### Theming (full token set)

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

### Style cascade

- `box` propagates `:border_style` to title.
- `table` accepts `:header_style`, `:row_style`, `:alt_row_style`,
  `:selected_style`, `:focus_style` (all default to theme).
- `Style.merge/2` with proper inheritance (child overrides parent;
  unspecified attrs inherit).

### tree / menu / select widgets

- `tree(:nodes, :expanded, :focused, :on_toggle, :on_select)` — recursive
  node display with expand/collapse on `Right`/`Left` or `Enter`.
- `menu(:items, :on_select)` — vertical list, arrow navigation, `Enter`
  selects.
- `select(:items, :value, :on_change)` — dropdown (uses `overlay` for the
  open state).

### Multi-line text_area

Builds on `text_input` + `viewport`. Word wrap, soft/hard line breaks,
proper cursor across wraps. Word movement (`Ctrl-Left`/`Ctrl-Right`),
line movement (`Up`/`Down` preserving visual column).

### Richer Sub kinds

- `Sub.pubsub(pubsub_mod, topic, transform_fn)` — subscribes via
  `Phoenix.PubSub`. Killer integration for Phoenix-based ops dashboards.
- `Sub.file(path, opts)` — watch via `:fs` if available, polling fallback.
- `Sub.signal(:sigusr1, msg)` — wraps `:os.set_signal/2`.
- `Sub.port(cmd, args)` — long-running external process, stdout lines as
  events.

---

## v0.5 — pre-1.0 hardening (~3 weeks)

- **Dialyzer clean** at `:underspecs` + `:overspecs`. Strict specs on all
  public functions.
- **Property-based tests** for layout solver (StreamData): for any list of
  constraints summing to ≥ 0, output sizes are non-negative and sum to
  total. For any frame diff: replay produces equivalent frame.
- **Benchmarks**: `Harlock.Bench` — render a 200×80 frame with N elements,
  measure µs per frame. Establish baseline, prevent regressions.
- **Documentation**: every public function has `@doc` + example. Module
  guides (`guides/getting_started.md`, `guides/widgets.md`,
  `guides/testing.md`, `guides/embedding.md`).
- **Examples expansion**: filemgr (two-pane), todo (text_input + list),
  log_viewer (viewport + filter), git_branch_picker (tree).
- **Caps refinement**: detect terminfo entries properly; fallback table for
  common terminals. Document the `Caps` API as public.
- **Public API freeze candidate**: walk every `@moduledoc false`, decide
  stable-public vs internal-forever. Move stable parts to `@moduledoc`
  proper.

## v1.0 — stable API, Hex release

- Public API frozen per the `@moduledoc` decisions above.
- All v0.5 hardening complete.
- Hex publish, hexdocs.pm live.
- Announcement post + Reddit/Elixir Forum thread.
- Minimum supported: Elixir 1.17+, OTP 26+ (decide closer to date).

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

## Notes for whoever picks this up

- The runtime is the spine. Don't add state to it casually — every field
  is load-bearing for focus/render/sub lifecycle. New features that need
  process state usually want their own GenServer, not a runtime field.
- The renderer is pure. Keep it that way. If you find yourself wanting
  `IO.puts` in there, you're doing it wrong.
- Always test the crash path. `smoke_crash/0` is the template — kill a
  linked process mid-render, assert the terminal is restored. New IO
  paths get the same treatment.
- Read the `App.Supervisor` comment block before changing supervisor
  config. The `rest_for_one` + `:temporary` runtime + Keeper-first
  ordering is the entire correctness argument for clean teardown.
