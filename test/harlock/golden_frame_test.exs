defmodule Harlock.GoldenFrameTest do
  use ExUnit.Case, async: false

  # docs/v0.4-plan.md Phase 3, load-bearing constraint:
  #
  #   :default theme MUST stay byte-identical to today's output
  #
  # The whole point of v0.4's theming work is to add new tokens and
  # cascade without regressing existing rendered output. This test pins
  # the raw byte stream a small canonical app produces under
  # Theme.default() so any accidental change to default styling — a new
  # token bleeding through, a renderer reaching for the wrong fallback,
  # a downgrade kicking in when it shouldn't — fails CI loudly.
  #
  # If a future change *intentionally* alters default output, update the
  # pinned hash here in the same commit. Don't update without explaining
  # why in the commit message: this assertion is the wall against silent
  # drift.

  defmodule CanonicalApp do
    use Harlock.App

    # Exercises every theme-token render path that's actually wired up:
    #   - box with a border (Theme.get(:border))
    #   - a table with a header row (Theme.get(:header))
    #   - the table's :focused_row, styled by Theme.get(:focus)
    #   - the table's :selection {:single, 2}, styled by Theme.get(:selection)
    #   - plain text (no theme involvement)
    def init(_) do
      %{rows: [%{id: 1, name: "alpha"}, %{id: 2, name: "beta"}]}
    end

    def update(_, m), do: m

    def view(m) do
      vbox(
        constraints: [length: 5, fill: 1],
        children: [
          box(
            title: "header",
            border: :single,
            child: text("body line")
          ),
          table(
            rows: m.rows,
            columns: [column(title: "Name", render: & &1.name)],
            row_id: & &1.id,
            focused_row: 1,
            selection: {:single, 2},
            focusable: :tbl
          )
        ]
      )
    end
  end

  test ":default theme output is byte-identical to the v0.3.0 baseline" do
    h = Harlock.Test.start_app(CanonicalApp, nil, rows: 10, cols: 30)
    raw = Harlock.Test.raw_writes(h)
    Harlock.Test.stop(h)

    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

    # Provenance: this hash was independently captured by running the
    # same CanonicalApp under a git worktree at tag v0.3.0 — NOT by
    # observing the v0.4-Phase-3 implementation and copying what it
    # emitted. The reproduction recipe (run once if you ever doubt the
    # baseline):
    #
    #   git worktree add /tmp/harlock-v0.3-baseline v0.3.0
    #   cd /tmp/harlock-v0.3-baseline
    #   # copy the CanonicalApp + Harlock.Test.start_app/raw_writes
    #   # boilerplate above into a script, hash with :crypto.hash/2
    #   mix deps.get && mix run that-script.exs
    #   git worktree remove /tmp/harlock-v0.3-baseline
    #
    # The v0.4 implementation must reproduce the same hash; any drift
    # means a default-theme regression slipped in.
    expected_hash = "20ded7e3f1ad2b828f58ef77715e5e69ff8da2b3d8245bba7ded0008cc27a1e9"

    assert hash == expected_hash, """
    :default theme rendered output drifted from the v0.3.0 baseline!

    Expected (v0.3.0): #{expected_hash}
    Actual   (HEAD):   #{hash}

    If this drift is intentional (e.g. an explicit visual change with
    a CHANGELOG note), update expected_hash in
    test/harlock/golden_frame_test.exs and explain in the commit
    message. Otherwise the render path silently changed what apps
    without a custom theme produce — investigate before merging.
    """
  end
end
