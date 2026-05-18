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

    # Exercises every styled element the renderer reaches for today:
    #   - box with a border (uses Theme.get(:border))
    #   - a focused box (uses Theme.get(:focus) via the box's border style cascade)
    #   - a table with header (Theme.get(:header))
    #   - a focused row (Theme.get(:focus))
    #   - a selected row (Theme.get(:selection))
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

  test ":default theme output is byte-identical to the v0.4-Phase-3 baseline" do
    h = Harlock.Test.start_app(CanonicalApp, nil, rows: 10, cols: 30)
    raw = Harlock.Test.raw_writes(h)
    Harlock.Test.stop(h)

    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

    # Baseline captured against the v0.4 Phase 3 implementation
    # (commit prep; theme defaults match v0.3 byte-for-byte). If you
    # are intentionally changing default rendered output, update this
    # hash in the same commit and explain why.
    expected_hash = "20ded7e3f1ad2b828f58ef77715e5e69ff8da2b3d8245bba7ded0008cc27a1e9"

    assert hash == expected_hash, """
    :default theme rendered output drifted!

    Expected: #{expected_hash}
    Actual:   #{hash}

    If this drift is intentional, update expected_hash in
    test/harlock/golden_frame_test.exs and explain why in the commit
    message. Otherwise something in the render path silently changed
    what apps without a custom theme produce.
    """
  end
end
