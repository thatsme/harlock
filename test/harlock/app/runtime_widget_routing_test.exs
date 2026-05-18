defmodule Harlock.App.RuntimeWidgetRoutingTest do
  use ExUnit.Case, async: false

  # R2: focus-aware key routing for stock widgets. When the focused
  # element is an auto-routable widget (currently :viewport), the
  # runtime translates scroll keys into {:harlock_scroll, focus_id,
  # new_offset} before delivering them to the app's update/2. Apps
  # opt out per-element with `handle_keys: false`.

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
end
