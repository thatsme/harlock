defmodule Harlock.TextInputTest do
  use ExUnit.Case, async: true

  defmodule InputApp do
    use Harlock.App

    def init(opts) do
      %{
        value: Keyword.get(opts, :value, ""),
        cursor: Keyword.get(opts, :cursor, 0),
        placeholder: Keyword.get(opts, :placeholder, ""),
        password: Keyword.get(opts, :password, false)
      }
    end

    # Since v0.4 the runtime auto-routes focused text_input keys; the
    # app just writes the routed messages back to the model.
    def update({:harlock_edit, :input, {v, c}}, m), do: %{m | value: v, cursor: c}
    def update(_, m), do: m

    def view(m) do
      text_input(
        value: m.value,
        cursor: m.cursor,
        focusable: :input,
        placeholder: m.placeholder,
        password: m.password
      )
    end
  end

  describe "rendering" do
    test "shows the value" do
      h = Harlock.Test.start_app(InputApp, [value: "hello", cursor: 5], rows: 1, cols: 20)
      assert Harlock.Test.render(h) =~ "hello"
      Harlock.Test.stop(h)
    end

    test "shows the placeholder when value is empty and not focused" do
      # `Tab` cycles to the only focusable, then `Tab` again wraps. Since there
      # is only one focusable, the input is always focused — for this test we
      # need to inspect via the unfocused render path: easiest is to assert
      # placeholder only appears in the unfocused branch. Skip with a focus-less
      # test by having no focusable element: use a separate app.
      defmodule PlaceholderApp do
        use Harlock.App

        def init(_), do: %{}
        def update(_, m), do: m

        def view(_) do
          vbox(
            children: [
              text("dummy", focusable: :dummy),
              text_input(value: "", cursor: 0, focusable: :input, placeholder: "search")
            ]
          )
        end
      end

      h = Harlock.Test.start_app(PlaceholderApp, nil, rows: 3, cols: 20)
      # First focusable is :dummy, so :input is not focused — placeholder shows.
      assert Harlock.Test.focused(h) == :dummy
      assert Harlock.Test.render(h) =~ "search"
      Harlock.Test.stop(h)
    end

    test "password masks each grapheme with •" do
      h =
        Harlock.Test.start_app(InputApp, [value: "secret", cursor: 6, password: true],
          rows: 1,
          cols: 20
        )

      output = Harlock.Test.render(h)
      refute output =~ "secret"
      assert output =~ "••••••"
      Harlock.Test.stop(h)
    end

    test "focused input sets Frame.cursor at the right column" do
      h = Harlock.Test.start_app(InputApp, [value: "hello", cursor: 3], rows: 1, cols: 20)
      assert Harlock.Test.focused(h) == :input
      assert Harlock.Test.cursor(h) == {0, 3}
      Harlock.Test.stop(h)
    end

    test "cursor column accounts for wide graphemes" do
      h = Harlock.Test.start_app(InputApp, [value: "東a", cursor: 2], rows: 1, cols: 20)
      # 東 (2 cols) + a (1 col) = cursor at col 3.
      assert Harlock.Test.cursor(h) == {0, 3}
      Harlock.Test.stop(h)
    end
  end

  describe "key handling via TextBuffer" do
    test "typing characters updates the model and moves the cursor" do
      h = Harlock.Test.start_app(InputApp, [], rows: 1, cols: 20)

      Harlock.Test.send_key(h, {:char, ?h})
      Harlock.Test.send_key(h, {:char, ?i})

      assert Harlock.Test.model(h).value == "hi"
      assert Harlock.Test.model(h).cursor == 2
      assert Harlock.Test.cursor(h) == {0, 2}

      Harlock.Test.stop(h)
    end

    test "backspace deletes the previous grapheme" do
      h = Harlock.Test.start_app(InputApp, [value: "hi", cursor: 2], rows: 1, cols: 20)
      Harlock.Test.send_key(h, :backspace)
      assert Harlock.Test.model(h).value == "h"
      Harlock.Test.stop(h)
    end

    test "arrow keys move the cursor without changing the value" do
      h = Harlock.Test.start_app(InputApp, [value: "hello", cursor: 3], rows: 1, cols: 20)
      Harlock.Test.send_key(h, :left)
      assert Harlock.Test.model(h).cursor == 2
      Harlock.Test.send_key(h, :right)
      Harlock.Test.send_key(h, :right)
      assert Harlock.Test.model(h).cursor == 4
      Harlock.Test.stop(h)
    end
  end
end
