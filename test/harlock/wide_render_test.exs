defmodule Harlock.WideRenderTest do
  use ExUnit.Case, async: true

  defmodule WideApp do
    use Harlock.App

    def init(content), do: %{content: content}
    def update(_, m), do: m

    def view(%{content: content}) do
      vbox(children: [text(content)])
    end
  end

  describe "wide-character rendering through Harlock.Test" do
    test "CJK text renders at correct visual width" do
      h = Harlock.Test.start_app(WideApp, "東京", rows: 3, cols: 10)

      output = Harlock.Test.render(h)
      [first_line | _] = String.split(output, "\n")

      # The grapheme count is 2 but visual width is 4 cells; cols=10 so
      # the line is padded out to 10 columns of *visual* width, which
      # means 2 wide graphemes + 6 spaces = 8 graphemes.
      assert first_line == "東京      "
      assert Harlock.Width.string_width(first_line) == 10

      Harlock.Test.stop(h)
    end

    test "mixed ASCII and CJK aligns column-wise" do
      h = Harlock.Test.start_app(WideApp, "a東b", rows: 3, cols: 10)

      output = Harlock.Test.render(h)
      [first_line | _] = String.split(output, "\n")

      assert first_line == "a東b      "
      assert Harlock.Width.string_width(first_line) == 10

      Harlock.Test.stop(h)
    end

    test "title in a box with CJK truncates by columns, not graphemes" do
      # Use a box with title — title cell wrap math has to use column widths.
      defmodule BoxApp do
        use Harlock.App
        def init(title), do: %{title: title}
        def update(_, m), do: m
        def view(%{title: t}), do: box(child: spacer(), title: t, border: :single)
      end

      # 12-col box: borders take 2 cols, available_w = 10 for the title.
      # Title " 東京 " = 6 cols (space + 東 + 京 + space = 1+2+2+1).
      h = Harlock.Test.start_app(BoxApp, "東京", rows: 3, cols: 12)
      output = Harlock.Test.render(h)
      [top, _, _] = String.split(output, "\n")

      # Title is left-aligned by default; the rest is filled with ─.
      assert top == "┌ 東京 ────┐"

      Harlock.Test.stop(h)
    end
  end
end
