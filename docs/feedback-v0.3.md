# v0.3 feedback — real-usage retrospective

Captured 2026-05-18. Feedback from building a real app against Harlock v0.3.
Architecture (TEA + supervised `Cmd`) is rated as the right foundation; the
gaps are in docs and the "last mile" of widget ergonomics.

This document is intentionally raw — it's the source material for v0.4
roadmap entries, not the roadmap itself. When v0.4 items land in
`ROADMAP.md`, link back here so the motivation isn't lost.

---

## The feedback, verbatim

> **Docs: Mostly accurate but uneven.** The source-level docstrings are good
> (Style, Theme, Viewport explain themselves). What's missing is a runnable
> end-to-end example — every API gotcha I hit (`text/1` is single-line,
> column `:render` returns string not Element, `apply_key` helpers exist for
> tabs/viewport/text_input) is documented in isolation but never shown
> working together. A 50-line "complete app with table + viewport +
> scrolling" in the README would have eliminated 80% of our back-and-forth.
>
> **Library leaving too much to the app:** For a v0.3 it's reasonable, but
> yes — there's a clear gap. `Harlock.Viewport.apply_key/4`,
> `Harlock.Tabs.apply_key/3`, and `Harlock.TextBuffer.apply_key/3` all exist
> precisely because the framework knows every app re-writes the same
> ↑/↓/PgUp/PgDn → offset and ←/→ → tab switch logic. But you still have to
> call them from your `update/2` and check `Focus.current()` yourself. A
> proper Elm-style framework would let widgets opt into "I handle navigation
> when focused" so you write zero key code for stock widgets. The author
> seems aware — v0.4 notes promise "more subscriptions" and richer theming.
>
> **Net:** it's a well-shaped foundation (TEA + supervised Cmd is the right
> architecture), but at v0.3 you're still writing roughly 30–40% of the
> boilerplate a mature TUI framework would absorb. Worth using if you like
> TEA and don't mind being an early adopter; not yet a drop-in replacement
> for ratatouille or Go's bubbletea.

---

## Distilled gaps

### G1. No end-to-end example

Source docstrings explain each module in isolation; nothing shows them
working together. New users hit the same gotchas in sequence:

- `text/1` is single-line (not a paragraph helper).
- column `:render` returns a `String.t()`, not an `Element`.
- `apply_key` helpers exist on Viewport, Tabs, TextBuffer but you must
  discover them by reading source.

**Cost:** ~80% of new-user questions are about wiring widgets together,
not about the widgets themselves.

### G2. Widgets don't own their key handling

`Harlock.Viewport.apply_key/4`, `Harlock.Tabs.apply_key/3`, and
`Harlock.TextBuffer.apply_key/3` exist *because* the maintainers know every
app re-implements:

- ↑ / ↓ / PgUp / PgDn → viewport offset
- ← / → → tab switch
- printable / Backspace → text buffer edit

But the app still has to:

1. Receive the key in `update/2`.
2. Check `Focus.current()` to know which widget is active.
3. Look up the focused widget's state on the model.
4. Call the right `apply_key` helper.
5. Put the result back on the model.

That's the "30–40% boilerplate" number. A focus-aware key-routing
mechanism — widgets declare "I handle navigation when focused" — would
collapse most of it.

### G3. Net positioning

At v0.3, app authors still write ~30–40% of the boilerplate a mature TUI
framework would absorb. The architecture is right; the ergonomics aren't
there yet. Not a drop-in replacement for ratatouille or bubbletea yet.

---

## Recommendations for v0.4 scope

Ordered by leverage-per-effort.

### R1. Ship a runnable end-to-end README example (highest leverage, ~1 day)

A 50-line "complete app with table + viewport + scrolling + focus" inline
in the README. Cheap to write, lives next to the code (so it can't rot
silently — CI should compile it), and pre-empts the top five new-user
questions.

Concrete acceptance:

- The example compiles as part of `mix test` or a doctest harness.
- It exercises: `Focus.next/prev`, viewport scrolling with `apply_key`,
  table with row selection, and at least one `Cmd` round-trip.
- Each gotcha from G1 is naturally demonstrated (no special call-outs
  needed — the example uses the right idiom).

### R2. Focus-aware key routing for stock widgets (~1 week, prototype first)

Mechanism for a widget to declare "I handle these keys when focused" so
the runtime dispatches them automatically, without the app's `update/2`
needing to know.

**Risk:** this is a renderer/runtime-contract change. Prior
viewport-contract work showed that renderer-contract changes blow past
their estimates — prototype narrowly first. Prototype against **one
widget end-to-end** (Viewport is the obvious choice — its key set is
small and well-understood) before generalizing to Tabs and TextBuffer.

Open design questions:

- How does the app opt *out* (e.g. a viewport inside a modal that wants
  custom keybindings)? Probably an explicit `handle_keys: false` option
  on the element.
- Does the widget mutate model state directly, or return a message the
  app's `update/2` still sees? The latter preserves the TEA single
  source of truth; the former is less code but harder to debug.
- Interaction with `Focus.current()` — the runtime already knows the
  focused element; this is just plumbing that knowledge into key
  dispatch.

### R3. Measure the boilerplate KPI

The "30–40%" number is the useful KPI for v0.4. Pick one of the existing
examples (`sysmon` or the v0.3 showcase) and count lines of `update/2`
that exist purely to wire `apply_key` helpers. After R2, the same count
should drop by half. If it doesn't, R2 missed the point.

---

## What this is *not*

- Not a commitment. v0.4 scope is set in `ROADMAP.md`; this doc informs
  prioritization.
- Not a critique of the architecture. The author explicitly rates TEA +
  supervised `Cmd` as the right foundation.
- Not a bug list. Everything here works as documented; the gap is in
  ergonomics and onboarding, not correctness.
