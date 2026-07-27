# Harlock Roadmap

A pure-Elixir TUI framework for Unix terminals. TEA-style model/update/view
loop on top of OTP, with a thin termios NIF for direct /dev/tty control.

This roadmap is the working plan through v1.0 (stable API). It's a living
document — revised as the design settles. v0.4.4 is current and published
on Hex.

## Status snapshot (v0.4.4, current)

What works:

- OTP supervision tree (`Keeper → Writer → Reader → Runtime`, `rest_for_one`,
  `max_restarts: 0`). Terminal is restored on any crash via
  `Keeper.terminate/2`. This is correct and load-bearing — don't regress it.
- TEA loop with `init/1`, `update/2`, `view/1`, optional `subs/1`. Dirty-flag
  rendering, no periodic polling.
- `Cmd` executor for supervised side effects: `Cmd.from/1`, `Cmd.batch/1`,
  `Cmd.map/2`. Results arrive back through `update/2` as messages.
- Focus traversal (`Tab` / `Shift-Tab`), focus traps for modals with
  automatic stash/restore on open/close.
- Focus-aware key routing (v0.4): the runtime dispatches navigation keys
  straight to the focused `viewport` / `tabs` / `text_input` and delivers the
  result as a message, so apps no longer hand-wire `apply_key` helpers.
- Constraint layout solver: `:length`, `:percentage`, `:fill`, `:min`, `:max`.
  Deterministic round-off absorption; graceful truncation on over-constraint
  (logs warning, never crashes).
- Cell-grid renderer with frame diffing. ANSI output via `Writer`.
- Theming (v0.4): full token set (`:header`, `:focus`, `:selection`,
  `:border`, `:primary`, `:accent`, `:muted`, `:error`), three built-in themes
  (`:default` / `:dark` / `:high_contrast`), caps-aware colour downgrade
  (truecolor → 256 → 16 → mono), and a table style cascade. `:default`-theme
  output is pinned byte-for-byte against v0.3.0 by a golden-frame test.
- Primitives: `text`, `vbox`, `hbox`, `spacer`, `box` (4 border styles +
  title + padding), `overlay` (5 anchors + focus trap), `table` / `list`
  (row-id identity, single/multi selection, header), `text_input`, `textarea`
  (multi-line, opt-in word wrap), `viewport`
  (render-then-clip + scroll-into-view + cursor remap), `progress`, `spinner`,
  `statusbar`, `keybar`, `tabs`.
- Wide-grapheme width (CJK, emoji, ZWJ sequences, flags).
- SIGWINCH resize via an `ioctl(TIOCGWINSZ)` NIF — terminal resize reflows.
- Input parser handles CSI/SS3, bracketed paste, XTerm focus reporting,
  modified arrows (`CSI 1;5A`), Home / End, and F-keys.
- `:telemetry` events for frame render, input dispatch, cmd, and reader.
- Headless `IO.Test` backend selectable via `backend: :test` for
  deterministic tests without a TTY, plus the `Harlock.Test` helper API.
- Examples: `counter`, `sysmon`, `contacts`, `showcase`, `overview`, `notes`,
  `explorer`. Smoke
  tests driven by `script(1)` (handles BSD vs util-linux flag differences).
- Packaging and quality gates: Hex package metadata, published hexdocs, CI,
  Dialyzer, and Credo all wired in.

What's stubbed / missing — the honest list:

- `Sub`: only `:interval` exists. Richer kinds (`pubsub` / `file` / `signal` /
  `port`) are v0.6.
- Mouse events: SGR parser only — runtime enabling is deferred.
- Kitty keyboard protocol: parser only — runtime push is deferred.
- No `tree`, `menu` / `select` widgets — v0.5.
- No `box(focus_proxy: id)` visual focus mirroring — v0.6.
- Windows native is unsupported (WSL works); the termios NIF targets POSIX.

## Guiding principles

1. **OTP-first.** The supervision tree is the architecture. New features
   that need processes get their own child, supervised correctly.
2. **No NIFs in the rendering path.** ANSI in, ANSI out. The termios NIF
   shipped in v0.2 is the one allowed exception, strictly scoped to
   /dev/tty control; new NIFs require the same level of justification.
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
  helper from `update/2`, no runtime interception.

### Mouse events (parser) ✓

Parser landed. Emits
`{:mouse, action, button | nil, col, row, mods}` for SGR encoding
(`CSI < button;col;row M|m`). Actions: `:press | :release | :drag |
:move | :wheel_up | :wheel_down`. Buttons: `:left | :middle | :right |
:extra4 | :extra5`.

**Runtime enabling + hit-test routing — deferred.** The runtime does
not write `\e[?1006h` by default and does not route events to elements.
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

## v0.5 — widgets on the new contract (next)

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

## v0.6 — subscriptions and focus polish

Split out of v0.5 so that milestone can close on the widget set alone.
Neither of these is a widget, and holding `tree` / `menu` / `select` back
until `Phoenix.PubSub` integration is also done would leave finished work
unpublished for no reason.

### Richer Sub kinds

- `Sub.pubsub(pubsub_mod, topic, transform_fn)` — subscribes via
  `Phoenix.PubSub`. The killer integration for Phoenix-based ops
  dashboards. Deferred from v0.4 because R2 took the cycle.
- `Sub.file(path, opts)` — watch via `:fs` if available, polling
  fallback.
- `Sub.signal(:sigusr1, msg)` — wraps `:os.set_signal/2`.
- `Sub.port(cmd, args)` — long-running external process, stdout lines
  as events.

### `box(focus_proxy: :child_id)`

Polish for the R2 visual story. With R2 default-on, `:focusable`
lives on the interactive widget (the viewport, the tabs, the text
input) — but the wrapping `box` is what users *see*. The
`focus_proxy:` opt lets a box mirror a named child's focus state for
visual highlighting only (border style, title style) without itself
participating in focus traversal. Until this lands, `examples/overview.exs`
styles its boxes' borders off `Focus.current()` by hand as a workaround
(see the `border_style/1` helper there).

---

## v0.7 — pre-1.0 hardening (~3 weeks)

- **Dialyzer clean** at `:underspecs` + `:overspecs`. Strict specs on all
  public functions.
- **Property-based tests** for layout solver (StreamData): for any list of
  constraints summing to ≥ 0, output sizes are non-negative and sum to
  total. For any frame diff: replay produces equivalent frame.
- **Benchmarks**: `Harlock.Bench` — render a 200×80 frame with N elements,
  measure µs per frame. Establish baseline, prevent regressions.
- **Incremental rewrap for `textarea`**, behind those benchmarks. Every motion
  and every render calls `visual_rows/2`, which rewraps the whole value — fine
  at a few hundred lines, poor at tens of thousands. The fix is to cache the
  line-break index and invalidate from the edited logical line forward, since
  everything above the edit is unchanged by construction. Deliberately after
  the benchmark: a wrap cache adds an invalidation boundary, which is exactly
  where wrap bugs hide, and it should not be added to chase an unmeasured
  number.
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

## v1.0 — stable API

- Public API frozen per the `@moduledoc` decisions above.
- All v0.7 hardening complete.
- Announcement post + Reddit/Elixir Forum thread.
- Minimum supported: Elixir 1.19+, OTP 26+ — matching the `elixir: "~> 1.19"`
  requirement `mix.exs` already ships.

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
