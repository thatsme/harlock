# Changelog

All notable changes to Harlock will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While on `0.x`, the public API may break between minor versions. Breaking
changes are called out in the relevant release notes.

## [Unreleased]

### Added

- **`Sub.telemetry/2` — subscribe to `:telemetry` events**, the first push-shaped
  subscription and the start of v0.6's event-source seam. Until now `Sub` had one
  kind, `:interval`, which is a *timer*: the runtime wakes itself. This is the
  other shape — an external source pushes and the runtime receives, without that
  source knowing anything about rendering.

      Sub.telemetry([:ecto, :repo, :query], &{:query, &1.query_time})

  Accepts one event name or a list of them, and a transform taking either the
  measurements alone or the full `(event, measurements, metadata)`. Since
  Phoenix, Ecto, Oban, Broadway, Finch and Bandit all already emit telemetry,
  integrating with that one thing covers all of them.

  Three things the implementation is shaped by rather than decorated with:

  A handler **runs inside whichever process emitted the event**, so work done
  there is stolen from the system being observed. The handler applies the
  transform and sends one message; nothing else. Events do not route through the
  owning process, which would put a second hop on the emitter's hot path.

  Handlers are **global and not processes**, so nothing detaches them when the
  app goes away — and a handler sending to a dead pid does not raise, so
  `:telemetry` never notices and drops it either. Left alone it leaks for the
  life of the VM and accumulates on every restart. Each subscription therefore
  owns a linked process whose lifetime *is* the subscription; it traps exits,
  because the runtime stops subs with `Process.exit(pid, :shutdown)` and a
  non-trapping process would die without cleaning up the very handler it exists
  to own. Pinned by a test that asserts the handler is gone after the app stops.

  The handler is a **named module function**, not a closure — `:telemetry` warns
  about anonymous handlers for real performance reasons. The transform rides in
  the config, where being anonymous costs nothing.

  Handler ids include the runtime pid, so two apps watching the same event do not
  silently unsubscribe each other.

  Documented consequence of `subs/1` being consulted while rendering: a
  push-shaped subscription is not listening until the first render completes, so
  events emitted before that are not delivered. It rarely matters for a dashboard
  watching a running system, but it makes this the wrong tool for capturing an
  app's own startup events — and it means a test that emits immediately after
  starting an app is racing the attach. `interval/2` is unaffected; it starts its
  own clock.

- **`sparkline/1` — a one-line trend**, the piece that makes a telemetry
  subscription worth looking at. `progress/1` shows one fraction; this shows a
  history. One cell per value using `▁▂▃▄▅▆▇█`, **right-aligned** so the newest
  sample stays at the right edge as history scrolls off the left.

  Auto-scaling spans the values *shown*, not the whole series, so it reports
  shape rather than magnitude — a series of 100s and a series of 3s draw
  identically, and narrowing the region can change the shape as the scale
  re-fits. `:min` and `:max` pin the range, which is usually what a dashboard
  wants. A flat series draws through the middle of the ramp rather than the
  bottom, because a steady value is not a zero one.

  The ramp is an explicit `:glyphs` option rather than something inferred from
  capabilities. The internal caps struct has no notion of glyph coverage and
  colour depth is not a proxy for it — a mono terminal renders block elements
  perfectly well — so an ASCII ramp is passed rather than guessed, matching
  `spinner`'s `:frames`.

- **`Sub.logger/1` — subscribe to log events**, the seam's second consumer. Takes
  `:level` (filtered by `:logger` before Harlock sees it), `:metadata` (keys to
  keep, or `:all`), and an optional `:transform`; delivers `{:log, entry}` where
  an entry is `%{level:, msg:, meta:}`.

  `Harlock.Sub.Logger.text/1` renders an entry, handling all three shapes
  `:logger` produces — `{:string, chardata}`, `{:report, term}`, and
  `{format, args}` — and degrading to `inspect/1` rather than raising on a
  malformed one, since a log viewer that dies on one bad entry is worse than one
  showing a placeholder.

  Messages arrive **unformatted on purpose**. A handler runs inside the process
  that called `Logger.info/1`, so formatting there bills the caller for the UI's
  work; `text/1` is meant to be called from `update/2`, where the cost lands on
  the runtime.

  Documented hazard with no equivalent in `telemetry/2`: **an app must not log
  from `update/2`**. Handling a delivered log event by logging produces another
  delivery, and it loops. Erlang's own recursion guard does not help, because the
  log originates in the runtime rather than inside the handler.

  Narrowing `:metadata` matters on a busy system — every entry is copied into the
  runtime's mailbox, and metadata can carry stacktraces and large structs.

  Worth recording for anyone building metadata search on top of this: the raw
  `:logger` event carries only `:domain`, `:gl`, `:pid` and `:time`. It does *not*
  carry `:module` or `:line` — Elixir adds those at formatting time, not into the
  event — so a search feature cannot assume they exist.

  The seam needed no changes to accommodate it, which was the point of building
  telemetry and logger as two deliberately different consumers rather than
  generalising from one.

- `Harlock.Sub`'s moduledoc now documents that specs are compared **structurally**,
  and the consequence for subs carrying functions: a closure built at a fixed
  code location with equal captures compares equal, so it does not churn — but a
  transform capturing something that changes each render produces a new spec
  every frame and restarts the subscription.

### Fixed

- **A terminal reporting 0x0 no longer produces a 0x0 frame.** `TIOCGWINSZ`
  *succeeds* while reporting zero rows and columns on a tty that was never told
  its geometry — a serial console is the usual case, and no `SIGWINCH` is coming
  to correct it later. The size fallback read `queried_rows || 24`, and `0 || 24`
  is `0` in Elixir, so the zero passed straight through. A 0x0 region makes the
  renderer return the frame untouched, so the result was a blank screen that
  reads as a hang rather than as a misconfiguration. Zero dimensions are now
  treated as "unknown", which is what they mean, so the 24x80 fallback applies.

  The `{:harlock_resize, rows, cols}` path is guarded the same way and keeps the
  previous dimensions rather than resizing to something that cannot draw.

## [0.5.0] — 2026-07-27

The widget set. `menu`, `select` and `tree` were deferred out of v0.4 so they
could be built as native consumers of the R2 routing contract rather than
against the manual-dispatch idiom it replaced; that contract shipped in v0.4 and
`textarea` proved it on the hardest case across v0.4.2–v0.4.3, so this closes
the milestone on the three of them plus the undo helper.

The whole set added **one** routed message — `{:harlock_toggle, …}`, which only
`tree` needed. Everything else reuses `{:harlock_select, …}` and
`{:harlock_submit, …}`, so an app that already handles `tabs` or `text_input`
has most of the vocabulary.

### Added

- **`menu/1` — a vertical menu**, backed by the new `Harlock.Menu`. Arrow keys
  move the highlight (wrapping at both ends), Home / End jump to the ends, and
  Enter commits. First of the three widgets v0.5 closes on.

  Movement and commitment are separate events, because they are separate
  intentions: arrows route `{:harlock_select, focus_id, id}` and Enter routes
  `{:harlock_submit, focus_id}`. An app that only wants the final choice
  ignores the first; one that previews as the highlight moves acts on both.
  Both tuples already existed — `tabs` produces the first, `text_input` the
  second — so the widget adds **no new message shape** to the routed contract.

  A key that would not move the highlight returns `:noop` and falls through to
  `update/2` as a raw key, rather than arriving as a message that selects what
  is already selected.

  Longer menus clip rather than scroll, matching `list/2`; wrap one in a
  `viewport/1` when it can outgrow its region. An unfocused menu keeps its
  highlight visible via the `:selection` token rather than dropping to the base
  style — losing focus should not lose your place.

- **`select/1` — a dropdown**, backed by the new `Harlock.Select`. Second of
  the three widgets v0.5 closes on. The app owns both the chosen value and
  whether the list is open, so it decides what closes it.

  The open list **flips rather than clips**: it opens below the control and
  left-aligned by default, above the control when there is no room below, and
  shifted left when it would run past the right margin. A dropdown on the last
  row of an 80x24 terminal opens upward instead of off-screen. Placement is
  pinned by tests at that exact size, including the corner case where both
  flips apply at once.

  Navigation delegates to `Harlock.Menu`, so both widgets move a highlight
  identically — same wrap, same noop-when-unmoved. Routing reuses the same two
  tuples as well: `{:harlock_select, …}` for movement, `{:harlock_submit, …}`
  for the action key. `:submit` means "the action key was pressed", and the app
  reads its own `:open` flag to know whether that opens the list or commits the
  highlight — it already has that information, so no open/close message shape
  had to be added to the routed contract.

  `Escape` deliberately falls through as a raw key rather than being consumed.
  Cancelling is not always local, and a widget that swallowed `Escape` would
  take that choice from the app.

- **`tree/1` — a collapsible tree**, backed by the new `Harlock.Tree`. Last of
  the three widgets v0.5 closes on. `Right` expands a collapsed node then
  descends into an open one, so repeated presses walk down; `Left` collapses
  then steps out to the parent; `Enter` toggles a branch and submits a leaf.

  **The renderer never walks the tree.** `Harlock.Tree.visible/2` projects it to
  the flat list of rows currently on screen, and the renderer draws rows. Each
  row carries its depth, whether it is the last of its siblings, its parent id,
  and `ancestors_last` — the last-child flag of every ancestor. That last field
  is what the guides actually need: depth alone cannot tell you whether column
  two of a nested row wants a `│` continuation or a blank, because that depends
  on whether *that ancestor* still had siblings coming. The renderer cannot see
  siblings, so the projection computes it.

  **Expansion is keyed by node id, never by row index.** Collapsing a node
  shifts every row beneath it, so index keys would silently move the selection
  to an unrelated node.

  **Lazy children are first-class.** A node's `:children` is either a list or
  one of `:unloaded` / `:loading`, so a tree over a filesystem or a remote node
  does not have to load eagerly. Expanding an unloaded node routes
  `{:harlock_toggle, id, node_id}`; the app marks it `:loading`, returns a
  `Cmd`, and swaps the fetched list in when the result arrives as an ordinary
  message. Expanding an unloaded node contributes no rows until then, and
  `:loading` renders with a suffix.

  Movement clamps rather than wrapping, unlike `menu` — a tree is read
  top-down, and jumping from the last leaf back to the root reads as a glitch
  rather than a convenience.

- **`Harlock.UndoStack` — bounded undo/redo for a `(value, cursor)` pair**, held
  by the app rather than the widget. `Harlock.TextBuffer` still has no history of
  its own, deliberately: the model owns `:value` and may rewrite it without the
  widget seeing — loading a file, clearing a form, applying a `Cmd` result — so a
  widget-held history would drift and start restoring text the user never typed.

  Snapshots rather than inverse commands: for buffers a terminal edits, copying
  the string beats the bookkeeping, and it cannot fall out of step with the text.
  Capped at 100 committed entries by default.

  **Coalescing is documented as contract, not tuning.** A run of insertions
  collapses into one step, and the run breaks on a newline, on a cursor jump, and
  on a delete following an insert. Coalescing too eagerly is worse than shipping
  no undo: a user who types a paragraph, presses undo expecting to lose a word,
  and loses the paragraph has had work destroyed rather than merely not restored.

  A cursor jump closes the run without becoming a step of its own — restoring a
  caret position while leaving the text unchanged would spend an undo press on
  something the user does not think of as a change. An in-progress run is its own
  nearest undo target, so undo works mid-word instead of waiting for the run to
  close. `reset/2` rebases history for when the app swaps the document outright.

  Wired to `Ctrl-Z` / `Ctrl-R` in `examples/notes.exs`.

- **`examples/explorer.exs`** — `tree`, `select` and `menu` in one app, so all
  three ship with something runnable rather than only documented. Its `deps`
  node starts unloaded, which makes the lazy path the example's default rather
  than a footnote: expanding it marks the node in flight, returns a `Cmd`, and
  the children arrive as an ordinary message. The filter dropdown opens over
  the tree, and the filtered node list is rebuilt in `update/2` rather than
  handed to the widget — the model owns what is displayed. Picked up
  automatically by `scripts/run.sh explorer`.

- **`{:harlock_toggle, focus_id, node_id}` — a fifth routed message**, and the
  only one the widget set needed. Expanding is not selecting, and a node whose
  children are not loaded yet makes the distinction load-bearing: the app has to
  know to fire a `Cmd`. Documented in `Harlock.App`'s moduledoc alongside the
  other four, since a 1.0 freeze locks it.

### Fixed

- **The NIF Makefile confused the build host with the build target**, which broke
  exactly the cross-compilation case that matters for embedded targets. `uname -s`
  describes the host, so building from macOS to ARM Linux — the common Nerves
  setup — appended Mach-O linker flags (`-undefined dynamic_lookup`,
  `-flat_namespace`) to a Linux link. Those branches are now gated on
  `CROSSCOMPILE`, which cross toolchains export.

  Two related hardenings in the same file: `-fPIC` is appended rather than living
  in the `?=` default, so a caller-supplied `CFLAGS` can no longer drop the one
  flag a shared object cannot link without; and the `ERTS_INCLUDE_DIR` fallback
  now *errors* under `CROSSCOMPILE` instead of quietly shelling out to the host's
  `erl`, which would have produced a NIF linked against the wrong ERTS and failed
  at load time on the device rather than at build time.

  The C source itself needed nothing — only POSIX headers, no platform
  conditionals.

### Changed

- The renderer gained a **deferred-draw layer** for content that must cover
  whatever the rest of the tree draws, regardless of where its element sits in
  that tree. `overlay/1` never needed it — it holds both layers as children, so
  its own subtree fixes the z-order — but a dropdown is anchored to a control
  buried in the layout, and every sibling rendered after that control would
  draw over it. Panels are recorded during the walk and drawn after it, in
  push order, so a panel opened from another panel lands on top without
  anything tracking depth. Internal (`@moduledoc false`).

## [0.4.4] — 2026-07-27

Input-parser fixes. Both bugs were reachable only from real terminal bytes,
which is why the v0.4.3 suite passed over them: the widget-level tests feed
synthesised key events straight to `apply_key/_`, so nothing exercised the
byte sequences a terminal actually sends.

### Fixed

- **`Alt-Backspace` now reaches the widgets that bind it.** v0.4.3 added the
  binding to `Harlock.TextBuffer` but nothing could deliver it: terminals send
  the chord as `ESC` followed by `DEL` (`0x7F`) or `BS` (`0x08`), and neither
  byte falls inside the `0x20..0x7E` printable range the ESC-prefix clause
  matched. The sequence decoded as two unrelated events instead, so
  backward-kill-word silently degraded to deleting a single grapheme.

  `Alt-B` / `Alt-F` were never affected — printable bytes take the ESC-prefix
  path, which is why word *motion* worked from the start while the word *kill*
  did not.

- **A bare `ESC` before an unhandled byte is now the Escape key, not codepoint
  27.** `0x1B` is a valid single-byte UTF-8 sequence, so any ESC that failed to
  begin a recognised CSI/SS3/Alt sequence fell through to the multibyte clause
  and surfaced as `{:key, {:char, 27}, []}` — printable text, for a keypress
  that has its own atom. Apps matching on `{:key, :escape, []}` missed it, and
  a focused `text_input` would have inserted it into the value.

Both are pinned by parser-level tests asserting on byte sequences rather than
on synthesised events.

## [0.4.3] — 2026-07-27

Finishes the textarea shipped in v0.4.2 rather than extending it. No new
widgets, and the routed-message contract is unchanged.

### Added

- **Goal-column memory for `textarea/1` vertical motion**, closing the gap
  v0.4.2 documented as open. Moving down through a short line and back now
  returns to the column you started in; previously each motion re-derived the
  column from the cursor, so one short row truncated it permanently and
  `↓↓↑↑` drifted left.

  The column lives in runtime state, keyed by focus, and is discarded on focus
  change. That keeps it out of the public message contract entirely —
  `{:harlock_edit, id, {value, cursor}}` is unchanged, and an app relying on
  R2 auto-routing gets the behaviour without holding the column itself. It is
  interaction state, not model state: the app model owns the value, and a
  goal column has no meaning to restore after the app rewrites it.

  `Harlock.TextArea.apply_key/6` is the goal-aware entry point, returning
  `{:edit, value, cursor, ring, goal_column}`. Vertical motion carries the
  goal, deriving it from the cursor when it arrives as `nil`; every other key
  resets it, which is what makes the next run start from wherever editing left
  off. Resetting lazily rather than recomputing the column per keystroke is
  deliberate — the column costs a full rewrap, and vertical motion should be
  the only thing paying for it.

  `move_up/3` and `move_down/3` stay goal-less: a single motion is unaffected,
  and a caller threading a run has state to hold anyway.

- **`Harlock.TextArea.expand_tabs/2`** — replaces tabs with spaces, advancing
  each to the next multiple of the given stop, measured in display cells so a
  tab after `日` advances from column 2.

  A tab is zero-width to `Harlock.Width` (every codepoint under `0x20` is), so
  a `\t` left in a value occupies a cursor index while consuming no display
  cell: wrapping ignores it and every index after it maps one column short of
  where it renders. The keyboard cannot produce one — the runtime consumes
  `Tab` for focus traversal before a widget sees it — so tabs arrive only from
  bracketed paste, which reaches `update/2` as `{:paste, text}`, or from an app
  assigning `:value`. Both are app-side, so normalising is offered as a helper
  rather than enforced at insert.

- **`Alt-Backspace` kills the word backward** in `text_input` and `textarea`,
  the other conventional chord for what `Ctrl-W` already did. Previously the
  backspace clause ignored modifiers, so it deleted a single grapheme.

- **`examples/notes.exs`** — a note editor built on `textarea`, the first
  runnable demo of the widget. Covers the single `update/2` clause that
  handles every edit, a wrap toggle, and normalising tabs out of pasted text.
  Picked up automatically by `scripts/run.sh notes`.

### Changed

- Widget key routing carries runtime state back to the caller, so a key that
  changes interaction state without changing value or cursor can record it and
  still fall through to `update/2` — an `↑` on the first row moves nothing but
  owns the column it aimed at. The runtime module is internal
  (`@moduledoc false`); no app-visible behaviour change beyond goal columns.

### Fixed

- `ROADMAP.md` no longer lists a missing `row.ex` helper among the project's
  limitations. `Harlock.Element.Column` is a table-column spec built by
  `column/1`, not a layout container, so `row` had no counterpart to be
  missing — horizontal layout is `hbox`, and per-row appearance is the table
  style cascade added in v0.4.

## [0.4.2] — 2026-07-27

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

  Not yet implemented: goal-column memory — vertical motion clamps the column
  to the target row rather than restoring the original on the next long row.
  Noted in `ROADMAP.md`.

- **Opt-in word wrap for `textarea/1`** via `wrap: true`. Long lines break at
  word boundaries across display rows, packing as many whole words as fit and
  hard-breaking a word longer than the width. Breaks are measured in display
  cells through `Harlock.Width`, so CJK wraps where the text actually reaches
  the edge rather than where its grapheme count does.

  With wrapping on, `↑` / `↓` and Home / End follow *display rows* rather than
  logical lines — pressing `↓` inside a wrapped paragraph moves down one
  visual row instead of past the whole paragraph — and `:scroll` counts
  display rows. Kills stay logical-line relative: `Ctrl-k` kills to the end of
  the line, not to the next wrap boundary, because that boundary isn't in the
  text. Wrapping is off by default, so existing textareas clip exactly as
  before.

  New pure helpers on `Harlock.TextArea`: `wrap_line/2`, `visual_rows/2`,
  `visual_position/3`, `visual_cursor_at/4`. Wrapped rows concatenate back to
  the original value exactly, which is what lets a flat cursor index map onto
  them without a translation table. `move_up/3`, `move_down/3`, `line_home/3`,
  `line_end/3` and `scroll_to_reveal/5` take an optional wrap width; passing
  `nil` keeps the previous logical-line behaviour, so the lower arities are
  unchanged.

  Vertical motion now preserves the *display* column rather than the grapheme
  index. This is a behaviour change for values containing wide graphemes even
  without wrapping — moving up a column of CJK text now lands where it looks
  like it should.

- The internal widget-metrics scratchpad grows a generic `record/2`,
  generalising the previously viewport-only helper so the renderer can hand a
  textarea's rendered wrap width back to the runtime for key routing. The
  viewport-specific function is retained and delegates to it. Internal
  (`@moduledoc false`); named in prose rather than linked, since hexdocs
  can't resolve references into hidden modules.

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

[Unreleased]: https://github.com/thatsme/harlock/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/thatsme/harlock/releases/tag/v0.5.0
[0.4.4]: https://github.com/thatsme/harlock/releases/tag/v0.4.4
[0.4.3]: https://github.com/thatsme/harlock/releases/tag/v0.4.3
[0.4.2]: https://github.com/thatsme/harlock/releases/tag/v0.4.2
[0.4.1]: https://github.com/thatsme/harlock/releases/tag/v0.4.1
[0.4.0]: https://github.com/thatsme/harlock/releases/tag/v0.4.0
[0.3.0]: https://github.com/thatsme/harlock/releases/tag/v0.3.0
[0.2.0]: https://github.com/thatsme/harlock/releases/tag/v0.2.0
[0.1.0]: https://github.com/thatsme/harlock/releases/tag/v0.1.0
