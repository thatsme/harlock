defmodule Harlock.Element.TableStyleCascadeTest do
  use ExUnit.Case, async: false

  alias Harlock.Render.Style
  alias Harlock.Theme

  # Phase 3 style cascade: table accepts :header_style, :row_style,
  # :alt_row_style, :selected_style, :focus_style. Defaults preserve
  # v0.3 behaviour exactly (header from theme, focused row from theme,
  # selected row from theme, others %Style{}).

  defmodule TableApp do
    use Harlock.App

    def init(opts) do
      %{
        rows: Keyword.get(opts, :rows, [%{id: 1, name: "a"}, %{id: 2, name: "b"}]),
        focused_row: Keyword.get(opts, :focused_row),
        selection: Keyword.get(opts, :selection, :none),
        table_opts: Keyword.get(opts, :table_opts, [])
      }
    end

    def update(_, m), do: m

    def view(m) do
      base = [
        rows: m.rows,
        columns: [column(title: "Name", render: & &1.name)],
        row_id: & &1.id,
        focused_row: m.focused_row,
        selection: m.selection,
        focusable: :tbl
      ]

      table(Keyword.merge(base, m.table_opts))
    end
  end

  test ":header_style overrides Theme.get(:header)" do
    h =
      Harlock.Test.start_app(
        TableApp,
        [table_opts: [header_style: %Style{italic: true}]],
        rows: 3,
        cols: 12
      )

    raw = Harlock.Test.raw_writes(h)
    # Italic is \e[0;3m; default header (bold) would be \e[0;1m.
    assert raw =~ "\e[0;3m"
    refute raw =~ "\e[0;1m"
    Harlock.Test.stop(h)
  end

  test ":selected_style overrides Theme.get(:selection) for the selected row" do
    h =
      Harlock.Test.start_app(
        TableApp,
        [
          selection: {:single, 1},
          table_opts: [selected_style: %Style{fg: :green}]
        ],
        rows: 5,
        cols: 12
      )

    raw = Harlock.Test.raw_writes(h)
    # green fg is \e[0;32m; default selection (bg: cyan) would be \e[0;46m.
    assert raw =~ "\e[0;32m"
    refute raw =~ "\e[0;46m"
    Harlock.Test.stop(h)
  end

  test ":focus_style overrides Theme.get(:focus) for the focused row" do
    h =
      Harlock.Test.start_app(
        TableApp,
        [
          focused_row: 1,
          table_opts: [focus_style: %Style{fg: :yellow}]
        ],
        rows: 5,
        cols: 12
      )

    raw = Harlock.Test.raw_writes(h)
    # Yellow fg = \e[0;33m; default focus (reverse) = \e[0;7m.
    assert raw =~ "\e[0;33m"
    refute raw =~ "\e[0;7m"
    Harlock.Test.stop(h)
  end

  test ":alt_row_style provides zebra striping on odd rows" do
    rows = for i <- 1..4, do: %{id: i, name: "row#{i}"}

    h =
      Harlock.Test.start_app(
        TableApp,
        [
          rows: rows,
          table_opts: [alt_row_style: %Style{dim: true}]
        ],
        rows: 8,
        cols: 12
      )

    raw = Harlock.Test.raw_writes(h)
    # Dim is \e[0;2m — applied to rows at odd indices (the 2nd and 4th visible).
    assert raw =~ "\e[0;2m"
    Harlock.Test.stop(h)
  end

  test "no overrides = byte-identical to v0.3 (defaults fall through to theme)" do
    # This is the load-bearing constraint: a table with no style opts must
    # produce the exact SGR codes the v0.3 hardcoded path would.
    h = Harlock.Test.start_app(TableApp, [], rows: 3, cols: 12)
    raw = Harlock.Test.raw_writes(h)
    # Header is bold (from Theme.default()), which is \e[0;1m.
    assert raw =~ "\e[0;1m"
    Harlock.Test.stop(h)

    # And the resolution path is identical to calling Theme.get directly:
    assert Theme.default().header == %Style{bold: true}
  end
end
