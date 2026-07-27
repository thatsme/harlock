defmodule Harlock.App.RuntimeWidgetRoutingTest do
  use ExUnit.Case, async: false

  # R2: focus-aware key routing for stock widgets. When the focused
  # element is an auto-routable widget (viewport, tabs, or text_input),
  # the runtime translates its handled keys into a widget-shaped
  # message ({:harlock_scroll | _select | _edit | _submit, focus_id,
  # _}) before delivering them to the app's update/2. No-op operations
  # fall through as raw {:key, …} so apps can still bind those gestures
  # for out-of-widget actions. Apps opt out per-element with
  # `handle_keys: false`.

  defmodule ScrollApp do
    @moduledoc false
    use Harlock.App

    def init(_) do
      %{offset: 0, lines: for(i <- 1..40, do: "line #{i}"), raw_keys: []}
    end

    def update({:harlock_scroll, :log, new_offset}, m), do: %{m | offset: new_offset}

    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}

    def update(_, m), do: m

    def view(m) do
      box(
        title: "log",
        border: :single,
        child:
          viewport(
            focusable: :log,
            offset: m.offset,
            content_height: length(m.lines),
            child:
              vbox(
                constraints: List.duplicate({:length, 1}, length(m.lines)),
                children: Enum.map(m.lines, &text/1)
              )
          )
      )
    end
  end

  defmodule OptOutApp do
    @moduledoc false
    use Harlock.App

    def init(_) do
      %{offset: 0, lines: for(i <- 1..40, do: "line #{i}"), raw_keys: []}
    end

    def update({:harlock_scroll, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}

    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}

    def update(_, m), do: m

    def view(m) do
      viewport(
        focusable: :log,
        handle_keys: false,
        offset: m.offset,
        content_height: length(m.lines),
        child:
          vbox(
            constraints: List.duplicate({:length, 1}, length(m.lines)),
            children: Enum.map(m.lines, &text/1)
          )
      )
    end
  end

  describe "default-on auto-routing" do
    setup do
      h = Harlock.Test.start_app(ScrollApp, nil, rows: 24, cols: 40)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test ":down on a focused viewport increments offset without app-side key code", %{h: h} do
      assert Harlock.Test.model(h).offset == 0
      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).offset == 1
      # And the app's raw-key fallback never saw a :down event.
      assert Harlock.Test.model(h).raw_keys == []
    end

    test ":page_down jumps by ~viewport_h using the recorded render height", %{h: h} do
      Harlock.Test.send_key(h, :page_down)
      # Box border eats 2 rows top + bottom = 2; viewport_h ≈ rows(24) - 2 = 22.
      # page_step = max(1, viewport_h - 1) ≈ 21. With content_height 40,
      # max_offset = 40 - 22 = 18, so the offset clamps to 18.
      assert Harlock.Test.model(h).offset == 18
    end

    test ":home / :end snap to extremes", %{h: h} do
      Harlock.Test.send_key(h, :end)
      assert Harlock.Test.model(h).offset > 0

      Harlock.Test.send_key(h, :home)
      assert Harlock.Test.model(h).offset == 0
    end

    test "a key that doesn't change offset falls through to update/2 as a raw event", %{h: h} do
      # offset is already 0, so :up clamps to 0 (no change) and the routing
      # should pass the raw key through instead of synthesizing a no-op
      # scroll message.
      assert Harlock.Test.model(h).offset == 0
      Harlock.Test.send_key(h, :up)
      assert Harlock.Test.model(h).offset == 0
      assert [{:key, :up, []}] = Harlock.Test.model(h).raw_keys
    end

    test "non-scroll keys flow to update/2 unchanged", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?x})
      assert [{:key, {:char, ?x}, []}] = Harlock.Test.model(h).raw_keys
    end
  end

  describe "handle_keys: false opt-out" do
    setup do
      h = Harlock.Test.start_app(OptOutApp, nil, rows: 24, cols: 40)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "scroll keys arrive as raw :key events; no auto-routed message", %{h: h} do
      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, :page_down)

      keys = Harlock.Test.model(h).raw_keys |> Enum.reverse()
      assert keys == [{:key, :down, []}, {:key, :page_down, []}]
      assert Harlock.Test.model(h).offset == 0
    end
  end

  defmodule TabsApp do
    @moduledoc false
    use Harlock.App

    def init(_), do: %{tab: :a, raw_keys: []}

    def update({:harlock_select, :nav, id}, m), do: %{m | tab: id}
    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}
    def update(_, m), do: m

    def view(m) do
      tabs(focusable: :nav, items: [{:a, "Alpha"}, {:b, "Beta"}, {:c, "Gamma"}], active: m.tab)
    end
  end

  describe "tabs auto-routing" do
    setup do
      h = Harlock.Test.start_app(TabsApp, nil, rows: 5, cols: 40)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "Right cycles to next tab without raw key delivery", %{h: h} do
      assert Harlock.Test.model(h).tab == :a
      Harlock.Test.send_key(h, :right)
      assert Harlock.Test.model(h).tab == :b
      assert Harlock.Test.model(h).raw_keys == []
    end

    test "Home jumps to first; Left wraps", %{h: h} do
      Harlock.Test.send_key(h, :end)
      assert Harlock.Test.model(h).tab == :c

      Harlock.Test.send_key(h, :right)
      assert Harlock.Test.model(h).tab == :a

      Harlock.Test.send_key(h, :left)
      assert Harlock.Test.model(h).tab == :c
    end

    test "Home on the first tab is a no-op and falls through to the app", %{h: h} do
      assert Harlock.Test.model(h).tab == :a
      Harlock.Test.send_key(h, :home)
      assert Harlock.Test.model(h).tab == :a
      assert [{:key, :home, []}] = Harlock.Test.model(h).raw_keys
    end

    test "End on the last tab is a no-op and falls through to the app", %{h: h} do
      Harlock.Test.send_key(h, :end)
      assert Harlock.Test.model(h).tab == :c
      # Now press End again — already on the last; should pass through raw.
      Harlock.Test.send_key(h, :end)
      assert Harlock.Test.model(h).tab == :c
      assert [{:key, :end, []}] = Harlock.Test.model(h).raw_keys
    end

    test "an unrelated key flows through unchanged", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?q})
      assert [{:key, {:char, ?q}, []}] = Harlock.Test.model(h).raw_keys
    end
  end

  defmodule InputApp do
    @moduledoc false
    use Harlock.App

    def init(_), do: %{value: "", cursor: 0, submits: 0, raw_keys: []}

    def update({:harlock_edit, :input, {v, c}}, m), do: %{m | value: v, cursor: c}
    def update({:harlock_submit, :input}, m), do: %{m | submits: m.submits + 1}
    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}
    def update(_, m), do: m

    def view(m) do
      text_input(focusable: :input, value: m.value, cursor: m.cursor)
    end
  end

  describe "text_input auto-routing" do
    setup do
      h = Harlock.Test.start_app(InputApp, nil, rows: 5, cols: 40)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "printable keys insert characters via the routed edit message", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?h})
      Harlock.Test.send_key(h, {:char, ?i})
      m = Harlock.Test.model(h)
      assert m.value == "hi"
      assert m.cursor == 2
      assert m.raw_keys == []
    end

    test "Backspace and arrows route through edit", %{h: h} do
      for c <- ~c"abc", do: Harlock.Test.send_key(h, {:char, c})
      assert Harlock.Test.model(h).value == "abc"

      Harlock.Test.send_key(h, :backspace)
      assert Harlock.Test.model(h).value == "ab"

      Harlock.Test.send_key(h, :left)
      assert Harlock.Test.model(h).cursor == 1
    end

    test "Enter delivers :harlock_submit", %{h: h} do
      Harlock.Test.send_key(h, :enter)
      assert Harlock.Test.model(h).submits == 1
      assert Harlock.Test.model(h).raw_keys == []
    end

    test "a modifier-only printable (e.g. Ctrl-x) is :noop and falls through", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?x}, [:ctrl])
      assert Harlock.Test.model(h).value == ""
      assert [{:key, {:char, ?x}, [:ctrl]}] = Harlock.Test.model(h).raw_keys
    end

    test "Left at cursor 0 is a no-op edit and falls through as raw :key", %{h: h} do
      # Cursor starts at 0; :left clamps to 0 in TextBuffer, so {:edit, ^value, ^cursor}
      # → :pass, and the raw key reaches the app's catch-all clause. This is the
      # scenario the maintainer cares about: an app that puts a text_input next to
      # another widget can rely on no-op cursor keys flowing through.
      assert Harlock.Test.model(h).cursor == 0
      Harlock.Test.send_key(h, :left)
      assert Harlock.Test.model(h).cursor == 0
      assert [{:key, :left, []}] = Harlock.Test.model(h).raw_keys
    end

    test "Right at end-of-value is a no-op edit and falls through as raw :key", %{h: h} do
      for c <- ~c"hi", do: Harlock.Test.send_key(h, {:char, c})
      # Drain any routed-edit raw_keys (there shouldn't be any) and re-baseline.
      assert Harlock.Test.model(h).raw_keys == []
      assert Harlock.Test.model(h).cursor == 2

      Harlock.Test.send_key(h, :right)
      assert Harlock.Test.model(h).cursor == 2
      assert [{:key, :right, []}] = Harlock.Test.model(h).raw_keys
    end

    test "Backspace on empty value is a no-op edit and falls through as raw :key", %{h: h} do
      assert Harlock.Test.model(h).value == ""
      Harlock.Test.send_key(h, :backspace)
      assert Harlock.Test.model(h).value == ""
      assert [{:key, :backspace, []}] = Harlock.Test.model(h).raw_keys
    end
  end

  defmodule TextareaApp do
    @moduledoc false
    use Harlock.App

    def init(_), do: %{body: "", cursor: 0, raw_keys: [], submits: 0}

    def update({:harlock_edit, :body, {v, c}}, m), do: %{m | body: v, cursor: c}

    def update({:harlock_submit, :body}, m), do: %{m | submits: m.submits + 1}

    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}

    def update(_, m), do: m

    def view(m), do: textarea(focusable: :body, value: m.body, cursor: m.cursor)
  end

  describe "textarea auto-routing" do
    setup do
      h = Harlock.Test.start_app(TextareaApp, nil, rows: 10, cols: 20)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "typing routes as :harlock_edit, same message a text_input produces", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?h})
      Harlock.Test.send_key(h, {:char, ?i})

      assert Harlock.Test.model(h).body == "hi"
      assert Harlock.Test.model(h).cursor == 2
      assert Harlock.Test.model(h).raw_keys == []
    end

    test "Enter inserts a newline and never submits", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?a})
      Harlock.Test.send_key(h, :enter)
      Harlock.Test.send_key(h, {:char, ?b})

      assert Harlock.Test.model(h).body == "a\nb"
      assert Harlock.Test.model(h).submits == 0
    end

    test "Up / Down move between lines", %{h: h} do
      for ch <- ~c"ab" do
        Harlock.Test.send_key(h, {:char, ch})
      end

      Harlock.Test.send_key(h, :enter)

      for ch <- ~c"cd" do
        Harlock.Test.send_key(h, {:char, ch})
      end

      # cursor is at end of line 1 (index 5 in "ab\ncd")
      assert Harlock.Test.model(h).cursor == 5

      Harlock.Test.send_key(h, :up)
      assert Harlock.Test.model(h).cursor == 2

      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).cursor == 5
    end

    test "Up on the first line is a no-op that falls through as a raw key", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?a})
      Harlock.Test.send_key(h, :up)

      assert Harlock.Test.model(h).cursor == 1
      assert [{:key, :up, []}] = Harlock.Test.model(h).raw_keys
    end

    test "Home / End are line-relative", %{h: h} do
      for ch <- ~c"ab" do
        Harlock.Test.send_key(h, {:char, ch})
      end

      Harlock.Test.send_key(h, :enter)

      for ch <- ~c"cd" do
        Harlock.Test.send_key(h, {:char, ch})
      end

      Harlock.Test.send_key(h, :home)
      assert Harlock.Test.model(h).cursor == 3

      Harlock.Test.send_key(h, :end)
      assert Harlock.Test.model(h).cursor == 5
    end

    test "Backspace at a line start joins the lines", %{h: h} do
      Harlock.Test.send_key(h, {:char, ?a})
      Harlock.Test.send_key(h, :enter)
      Harlock.Test.send_key(h, {:char, ?b})
      Harlock.Test.send_key(h, :home)

      assert Harlock.Test.model(h).body == "a\nb"

      Harlock.Test.send_key(h, :backspace)
      assert Harlock.Test.model(h).body == "ab"
    end

    test "Tab still moves focus rather than being consumed as input", %{h: h} do
      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.model(h).body == ""
    end
  end

  defmodule WrapApp do
    @moduledoc false
    use Harlock.App

    # At cols: 10 this wraps into ["aaa bbb ", "ccc"] — one logical line, two
    # display rows.
    def init(_), do: %{body: "aaa bbb ccc", cursor: 0, raw_keys: []}

    def update({:harlock_edit, :body, {v, c}}, m), do: %{m | body: v, cursor: c}

    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}

    def update(_, m), do: m

    def view(m), do: textarea(focusable: :body, value: m.body, cursor: m.cursor, wrap: true)
  end

  describe "textarea wrapping routes vertical motion by display row" do
    setup do
      h = Harlock.Test.start_app(WrapApp, nil, rows: 10, cols: 10)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "Down moves to the next wrapped row of the same logical line", %{h: h} do
      # Without the wrap width reaching the runtime this would be a no-op,
      # because there is only one logical line to move to.
      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).cursor == 8
      assert Harlock.Test.model(h).raw_keys == []
    end

    test "Up returns to the previous wrapped row", %{h: h} do
      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, :up)
      assert Harlock.Test.model(h).cursor == 0
    end

    test "End goes to the end of the wrapped row, not the logical line", %{h: h} do
      Harlock.Test.send_key(h, :end)
      assert Harlock.Test.model(h).cursor == 8
    end

    test "Ctrl-End still goes to the end of the whole value", %{h: h} do
      Harlock.Test.send_key(h, :end, [:ctrl])
      assert Harlock.Test.model(h).cursor == 11
    end
  end
end
