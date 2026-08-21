defmodule Harlock.App.RuntimeWidgetRoutingTest do
  use ExUnit.Case, async: false

  # R2: focus-aware key routing for stock widgets. When the focused
  # element is an auto-routable widget (`@auto_routed_types` in
  # `Harlock.Element.Focusables`), the runtime translates its handled
  # keys into a widget-shaped message ({:harlock_scroll | _select |
  # _toggle | _edit | _submit, focus_id, _}) before delivering them to
  # the app's update/2. No-op operations
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

  defmodule ListTableApp do
    @moduledoc false
    use Harlock.App

    def init(_), do: %{focused: 1, raw_keys: []}

    def update({:harlock_select, :rows, id}, m), do: %{m | focused: id}
    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}
    def update(_, m), do: m

    def view(m) do
      table(
        focusable: :rows,
        columns: [column(title: "n", width: {:fill, 1}, render: &to_string(&1.id))],
        rows: for(i <- 1..5, do: %{id: i}),
        row_id: & &1.id,
        focused_row: m.focused
      )
    end
  end

  defmodule WindowTableApp do
    @moduledoc false
    use Harlock.App

    # 40 rows behind a window function, so scrolling has somewhere to go and an
    # end to reach.
    def init(_), do: %{offset: 0, raw_keys: []}

    def update({:harlock_scroll, :rows, offset}, m), do: %{m | offset: offset}
    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}
    def update(_, m), do: m

    def view(m) do
      table(
        focusable: :rows,
        columns: [column(title: "n", width: {:fill, 1}, render: &to_string(&1.id))],
        row_id: & &1.id,
        offset: m.offset,
        rows: fn offset, limit ->
          for i <- offset..(offset + limit - 1), i < 40, do: %{id: i}
        end
      )
    end
  end

  describe "table auto-routing: enumerable rows move focus" do
    setup do
      h = Harlock.Test.start_app(ListTableApp, nil, rows: 8, cols: 20)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "Down and Up move :focused_row", %{h: h} do
      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).focused == 2

      Harlock.Test.send_key(h, :up)
      assert Harlock.Test.model(h).focused == 1
      assert Harlock.Test.model(h).raw_keys == []
    end

    test "End jumps to the last row", %{h: h} do
      Harlock.Test.send_key(h, :end)
      assert Harlock.Test.model(h).focused == 5
    end

    test "movement past the end falls through as a raw key", %{h: h} do
      Harlock.Test.send_key(h, :up)

      assert Harlock.Test.model(h).focused == 1
      assert [{:key, :up, []}] = Harlock.Test.model(h).raw_keys
    end
  end

  describe "table auto-routing: a window function moves :offset" do
    setup do
      h = Harlock.Test.start_app(WindowTableApp, nil, rows: 8, cols: 20)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "Down scrolls rather than selecting", %{h: h} do
      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).offset == 1
      assert Harlock.Test.model(h).raw_keys == []
    end

    test "Up at the top falls through", %{h: h} do
      Harlock.Test.send_key(h, :up)
      assert Harlock.Test.model(h).offset == 0
      assert [{:key, :up, []}] = Harlock.Test.model(h).raw_keys
    end

    test "paging uses the rendered body height", %{h: h} do
      # 8 rows minus the header leaves 7 of body, so a page is 6
      Harlock.Test.send_key(h, :page_down)
      assert Harlock.Test.model(h).offset == 6
    end

    test "scrolling stops once a fetch comes back short", %{h: h} do
      # walk to the end; the source has 40 rows and the body draws 7
      for _ <- 1..12, do: Harlock.Test.send_key(h, :page_down)
      settled = Harlock.Test.model(h).offset

      Harlock.Test.send_key(h, :page_down)
      assert Harlock.Test.model(h).offset == settled

      # and the refused key reaches update/2 rather than vanishing
      assert Enum.any?(Harlock.Test.model(h).raw_keys, &match?({:key, :page_down, []}, &1))
    end

    test "Home returns to the top from anywhere", %{h: h} do
      Harlock.Test.send_key(h, :page_down)
      Harlock.Test.send_key(h, :home)
      assert Harlock.Test.model(h).offset == 0
    end
  end

  defmodule TreeApp do
    @moduledoc false
    use Harlock.App

    # :lazy starts unloaded, so expanding it has to go through a Cmd.
    def init(observer) do
      %{
        observer: observer,
        nodes: [
          %{
            id: :root,
            label: "root",
            children: [
              %{id: :leaf, label: "leaf", children: []},
              %{id: :lazy, label: "lazy", children: :unloaded}
            ]
          }
        ],
        expanded: MapSet.new(),
        focused: :root,
        submits: 0,
        raw_keys: []
      }
    end

    def update({:harlock_select, :files, id}, m), do: %{m | focused: id}

    # Expanding an unloaded node is a side effect: mark it in flight, fire the
    # fetch, and let the result arrive as an ordinary message.
    def update({:harlock_toggle, :files, :lazy}, %{expanded: exp} = m) do
      if MapSet.member?(exp, :lazy) do
        %{m | expanded: MapSet.delete(exp, :lazy)}
      else
        {
          %{m | expanded: MapSet.put(exp, :lazy), nodes: set_children(m.nodes, :lazy, :loading)},
          Cmd.from(fn -> {:loaded, :lazy, [%{id: :kid, label: "kid", children: []}]} end)
        }
      end
    end

    def update({:harlock_toggle, :files, id}, %{expanded: exp} = m) do
      exp = if MapSet.member?(exp, id), do: MapSet.delete(exp, id), else: MapSet.put(exp, id)
      %{m | expanded: exp}
    end

    def update({:loaded, id, children}, m) do
      if m.observer, do: send(m.observer, {:children_loaded, id})
      %{m | nodes: set_children(m.nodes, id, children)}
    end

    def update({:harlock_submit, :files}, m), do: %{m | submits: m.submits + 1}
    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}
    def update(_, m), do: m

    def view(m) do
      tree(focusable: :files, nodes: m.nodes, expanded: m.expanded, focused: m.focused)
    end

    defp set_children(nodes, id, children) do
      Enum.map(nodes, fn
        %{id: ^id} = n ->
          %{n | children: children}

        %{children: list} = n when is_list(list) ->
          %{n | children: set_children(list, id, children)}

        n ->
          n
      end)
    end
  end

  defmodule SelectApp do
    @moduledoc false
    use Harlock.App

    @items [{:it, "Italy"}, {:fr, "France"}, {:de, "Germany"}]

    def init(_), do: %{value: :it, highlight: :it, open: false, raw_keys: []}

    # Movement only ever moves the highlight; the value changes when committed.
    def update({:harlock_select, :country, id}, m), do: %{m | highlight: id}

    def update({:harlock_submit, :country}, %{open: false} = m), do: %{m | open: true}

    def update({:harlock_submit, :country}, %{open: true} = m),
      do: %{m | open: false, value: m.highlight}

    def update({:key, :escape, []}, %{open: true} = m), do: %{m | open: false, highlight: m.value}

    def update({:key, _, _} = ev, m), do: %{m | raw_keys: [ev | m.raw_keys]}

    def update(_, m), do: m

    def view(m) do
      vbox(
        constraints: [length: 1, fill: 1],
        children: [
          select(
            focusable: :country,
            items: @items,
            value: m.value,
            highlight: m.highlight,
            open: m.open
          ),
          # Drawn after the select, so it would bury an inline dropdown.
          text("XXXXXXXXXXXXXXXX")
        ]
      )
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

  describe "tree auto-routing" do
    setup do
      h = Harlock.Test.start_app(TreeApp, self(), rows: 10, cols: 30)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "Right expands, then descends on the next press", %{h: h} do
      Harlock.Test.send_key(h, :right)
      assert MapSet.member?(Harlock.Test.model(h).expanded, :root)
      # focus has not moved yet
      assert Harlock.Test.model(h).focused == :root

      Harlock.Test.send_key(h, :right)
      assert Harlock.Test.model(h).focused == :leaf
    end

    test "Left collapses, then steps out to the parent", %{h: h} do
      Harlock.Test.send_key(h, :right)
      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).focused == :leaf

      Harlock.Test.send_key(h, :left)
      assert Harlock.Test.model(h).focused == :root
      # still expanded — Left on a leaf steps out rather than collapsing a parent
      assert MapSet.member?(Harlock.Test.model(h).expanded, :root)

      Harlock.Test.send_key(h, :left)
      refute MapSet.member?(Harlock.Test.model(h).expanded, :root)
    end

    test "Enter submits on a leaf and toggles on a branch", %{h: h} do
      Harlock.Test.send_key(h, :enter)
      assert MapSet.member?(Harlock.Test.model(h).expanded, :root)
      assert Harlock.Test.model(h).submits == 0

      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, :enter)
      assert Harlock.Test.model(h).submits == 1
    end

    test "expanding an unloaded node fires a Cmd and the children arrive", %{h: h} do
      Harlock.Test.send_key(h, :right)
      Harlock.Test.send_key(h, :end)
      assert Harlock.Test.model(h).focused == :lazy

      # marked in flight and rendered as such before the fetch returns
      Harlock.Test.send_key(h, :right)

      # the Cmd result arrives as an ordinary message, which is the whole point:
      # a lazily loaded tree needs no widget-level machinery
      assert_receive {:children_loaded, :lazy}, 500

      # the app notifies from inside update/2, so the frame it produces is not
      # drawn yet. model/1 is a :sys.get_state call, which queues behind that
      # same handle_info and therefore returns only once its render is done.
      assert MapSet.member?(Harlock.Test.model(h).expanded, :lazy)

      frame = Harlock.Test.render(h)
      assert frame =~ "kid"
      assert frame =~ "▾ lazy"
      refute frame =~ "…"
    end

    test "the tree renders its guides through the runtime", %{h: h} do
      Harlock.Test.send_key(h, :right)
      frame = Harlock.Test.render(h)

      assert frame =~ "▾ root"
      assert frame =~ "├──"
      assert frame =~ "└──"
    end
  end

  describe "select auto-routing" do
    setup do
      h = Harlock.Test.start_app(SelectApp, nil, rows: 10, cols: 20)
      on_exit(fn -> Harlock.Test.stop(h) end)
      {:ok, h: h}
    end

    test "Enter opens, arrows move the highlight, Enter commits", %{h: h} do
      Harlock.Test.send_key(h, :enter)
      assert Harlock.Test.model(h).open

      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).highlight == :fr
      # not committed yet
      assert Harlock.Test.model(h).value == :it

      Harlock.Test.send_key(h, :enter)
      m = Harlock.Test.model(h)
      refute m.open
      assert m.value == :fr
    end

    test "the value does not change while closed", %{h: h} do
      Harlock.Test.send_key(h, :up)
      Harlock.Test.send_key(h, :home)

      m = Harlock.Test.model(h)
      assert m.value == :it
      assert m.highlight == :it
      refute m.open
    end

    test "Escape falls through so the app can cancel the move", %{h: h} do
      Harlock.Test.send_key(h, :enter)
      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).highlight == :fr

      Harlock.Test.send_key(h, :escape)
      m = Harlock.Test.model(h)
      refute m.open
      # the app reverted the highlight; the value was never touched
      assert m.highlight == :it
      assert m.value == :it
    end

    test "the open list draws over content rendered after the control", %{h: h} do
      Harlock.Test.send_key(h, :enter)
      frame = Harlock.Test.render(h)

      # the sibling text sits on row 1, exactly where the dropdown opens
      assert frame =~ "France"
      refute frame =~ "XXXXXXXXXXXXXXXX"
    end

    test "the closed control shows the chosen label and a marker", %{h: h} do
      frame = Harlock.Test.render(h)
      assert frame =~ "Italy"
      assert frame =~ "▾"
      refute frame =~ "France"
    end
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

    test "a run of vertical motion keeps the goal column across keypresses", %{h: h} do
      # "abcd\nx\nabcd" — the one-column middle row is where a goal-less
      # implementation would truncate and never recover.
      for ch <- ~c"abcd", do: Harlock.Test.send_key(h, {:char, ch})
      Harlock.Test.send_key(h, :enter)
      Harlock.Test.send_key(h, {:char, ?x})
      Harlock.Test.send_key(h, :enter)
      for ch <- ~c"abcd", do: Harlock.Test.send_key(h, {:char, ch})

      assert Harlock.Test.model(h).body == "abcd\nx\nabcd"
      assert Harlock.Test.model(h).cursor == 11

      Harlock.Test.send_key(h, :up)
      # clamped onto the short row
      assert Harlock.Test.model(h).cursor == 6

      Harlock.Test.send_key(h, :up)
      # column 4 restored rather than inherited from the clamp (which would be 1)
      assert Harlock.Test.model(h).cursor == 4

      Harlock.Test.send_key(h, :down)
      Harlock.Test.send_key(h, :down)
      assert Harlock.Test.model(h).cursor == 11
    end

    test "editing between vertical motions restarts the goal", %{h: h} do
      for ch <- ~c"abcd", do: Harlock.Test.send_key(h, {:char, ch})
      Harlock.Test.send_key(h, :enter)
      Harlock.Test.send_key(h, {:char, ?x})
      Harlock.Test.send_key(h, :enter)
      for ch <- ~c"abcd", do: Harlock.Test.send_key(h, {:char, ch})

      Harlock.Test.send_key(h, :up)
      assert Harlock.Test.model(h).cursor == 6

      # typing on the short row makes *that* column the new goal
      Harlock.Test.send_key(h, {:char, ?y})
      assert Harlock.Test.model(h).body == "abcd\nxy\nabcd"

      Harlock.Test.send_key(h, :up)
      assert Harlock.Test.model(h).cursor == 2
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
