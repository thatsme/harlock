defmodule Harlock.ThemeTest do
  use ExUnit.Case, async: true

  alias Harlock.Render.Style
  alias Harlock.Theme

  describe "default/0" do
    test "matches the pre-theming hard-coded values" do
      theme = Theme.default()
      assert theme.header == %Style{bold: true}
      assert theme.focus == %Style{reverse: true}
      assert theme.selection == %Style{bg: :cyan}
      assert theme.border == %Style{}
    end

    test "carries v0.4 generic tokens with sensible defaults" do
      theme = Theme.default()
      assert theme.primary == %Style{fg: :cyan}
      assert theme.accent == %Style{fg: :magenta}
      assert theme.muted == %Style{dim: true}
      assert theme.error == %Style{fg: :red}
    end
  end

  describe "builtin/1" do
    test ":default is identical to default/0" do
      assert Theme.builtin(:default) == Theme.default()
    end

    test ":dark uses bright colours and a coloured border" do
      theme = Theme.builtin(:dark)
      assert theme.border.fg == :bright_black
      assert theme.primary.fg == :bright_cyan
      assert theme.error.bold == true
    end

    test ":high_contrast bolds primaries and underlines errors" do
      theme = Theme.builtin(:high_contrast)
      assert theme.primary.bold == true
      assert theme.error.underline == true
      assert theme.focus.bold == true
    end
  end

  describe "get/1 for new tokens" do
    test ":primary/:accent/:muted/:error all resolve through Theme.get" do
      Theme.__set__(Theme.builtin(:dark))
      assert Theme.get(:primary) == %Style{fg: :bright_cyan}
      assert Theme.get(:error).bold == true
      Theme.__clear__()
    end
  end

  describe "build/1" do
    test "from a struct passes through" do
      theme = %Theme{focus: %Style{bold: true}}
      assert Theme.build(theme) == theme
    end

    test "from a keyword list merges with defaults" do
      theme = Theme.build(focus: %Style{fg: :red})
      assert theme.focus == %Style{fg: :red}
      assert theme.header == %Style{bold: true}
    end

    test "from a map merges with defaults" do
      theme = Theme.build(%{header: %Style{italic: true}})
      assert theme.header == %Style{italic: true}
      assert theme.focus == %Style{reverse: true}
    end
  end

  describe "get/1 in scope" do
    test "returns the installed theme's value" do
      Theme.__set__(%Theme{focus: %Style{fg: :magenta}})
      assert Theme.get(:focus) == %Style{fg: :magenta}
      Theme.__clear__()
    end

    test "falls back to default outside a callback" do
      Theme.__clear__()
      assert Theme.get(:focus) == %Style{reverse: true}
    end
  end

  describe "Style.merge/2" do
    test "non-default colors in over win" do
      under = %Style{fg: :red}
      over = %Style{fg: :blue}
      assert Style.merge(under, over) == %Style{fg: :blue}
    end

    test ":default in over leaves under's color" do
      under = %Style{fg: :red}
      over = %Style{bold: true}
      assert Style.merge(under, over) == %Style{fg: :red, bold: true}
    end

    test "boolean attrs OR together" do
      under = %Style{bold: true}
      over = %Style{reverse: true}
      assert Style.merge(under, over) == %Style{bold: true, reverse: true}
    end
  end

  describe "renderer integration" do
    defmodule TableApp do
      use Harlock.App

      def init(_), do: %{rows: [%{id: 1, name: "alpha"}]}
      def update(_, m), do: m

      def view(m) do
        table(
          rows: m.rows,
          columns: [column(title: "Name", render: & &1.name)],
          row_id: & &1.id,
          focused_row: 1,
          focusable: :tbl
        )
      end
    end

    test "default theme keeps header bold" do
      h = Harlock.Test.start_app(TableApp, nil, rows: 3, cols: 10)
      raw = Harlock.Test.raw_writes(h)
      # Bold SGR is `\e[0;1m` (reset then bold).
      assert raw =~ "\e[0;1m"
      Harlock.Test.stop(h)
    end

    test "custom header theme changes the header SGR" do
      theme = Theme.build(header: %Style{italic: true})
      h = Harlock.Test.start_app(TableApp, nil, rows: 3, cols: 10, theme: theme)
      raw = Harlock.Test.raw_writes(h)
      # Italic is `\e[0;3m`.
      assert raw =~ "\e[0;3m"
      refute raw =~ "\e[0;1m"
      Harlock.Test.stop(h)
    end

    test "custom focus theme changes the focused-row SGR" do
      theme = Theme.build(focus: %Style{fg: :yellow})
      h = Harlock.Test.start_app(TableApp, nil, rows: 3, cols: 10, theme: theme)
      raw = Harlock.Test.raw_writes(h)
      # Standard yellow fg is `\e[0;33m`.
      assert raw =~ "\e[0;33m"
      Harlock.Test.stop(h)
    end
  end

  describe "Theme.get in user callbacks" do
    defmodule ReadingApp do
      use Harlock.App

      def init(observer), do: %{observer: observer}

      def update(_event, m) do
        send(m.observer, {:theme_during_update, Harlock.Theme.get(:focus)})
        m
      end

      def view(m) do
        send(m.observer, {:theme_during_view, Harlock.Theme.get(:focus)})
        text("hello")
      end
    end

    test "view sees the installed theme" do
      theme = Theme.build(focus: %Style{fg: :green})
      h = Harlock.Test.start_app(ReadingApp, self(), rows: 3, cols: 10, theme: theme)
      # The first render runs view once.
      assert_receive {:theme_during_view, %Style{fg: :green}}
      Harlock.Test.stop(h)
    end

    test "update sees the installed theme" do
      theme = Theme.build(focus: %Style{fg: :green})
      h = Harlock.Test.start_app(ReadingApp, self(), rows: 3, cols: 10, theme: theme)
      Harlock.Test.send_key(h, {:char, ?x})
      assert_receive {:theme_during_update, %Style{fg: :green}}
      Harlock.Test.stop(h)
    end
  end
end
