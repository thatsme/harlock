defmodule Harlock.ResizeTest do
  use ExUnit.Case, async: true

  defmodule SizeApp do
    use Harlock.App

    def init(observer), do: %{observer: observer}

    def update(_event, m), do: m

    def view(_) do
      vbox(
        children: [
          text("top"),
          text("bottom")
        ]
      )
    end
  end

  describe "resize" do
    test "updates the runtime's stored dimensions" do
      h = Harlock.Test.start_app(SizeApp, self(), rows: 24, cols: 80)
      state = :sys.get_state(h.runtime)
      assert state.rows == 24
      assert state.cols == 80

      Harlock.Test.resize(h, 40, 120)

      state = :sys.get_state(h.runtime)
      assert state.rows == 40
      assert state.cols == 120

      Harlock.Test.stop(h)
    end

    test "discards prev_frame so the next diff is a full redraw" do
      h = Harlock.Test.start_app(SizeApp, self(), rows: 24, cols: 80)
      assert :sys.get_state(h.runtime).prev_frame != nil

      Harlock.Test.resize(h, 40, 120)

      # After resize + re-render, prev_frame is non-nil again (the new frame
      # at the new size), so just assert dimensions cascaded through.
      frame = :sys.get_state(h.runtime).prev_frame
      assert frame != nil
      assert frame.buffer.rows == 40
      assert frame.buffer.cols == 120

      Harlock.Test.stop(h)
    end

    test "renders the view into the new dimensions" do
      h = Harlock.Test.start_app(SizeApp, self(), rows: 24, cols: 80)
      Harlock.Test.resize(h, 10, 30)

      output = Harlock.Test.render(h)
      lines = String.split(output, "\n")
      assert length(lines) == 10
      assert Enum.all?(lines, &(String.length(&1) == 30))
      # Content is still rendered at the new size.
      assert output =~ "top"
      assert output =~ "bottom"

      Harlock.Test.stop(h)
    end

    test "successive resizes converge to the last one" do
      h = Harlock.Test.start_app(SizeApp, self(), rows: 24, cols: 80)

      Harlock.Test.resize(h, 40, 100)
      Harlock.Test.resize(h, 20, 50)
      Harlock.Test.resize(h, 30, 60)

      state = :sys.get_state(h.runtime)
      assert {state.rows, state.cols} == {30, 60}

      Harlock.Test.stop(h)
    end

    test "same-size event still re-renders without crashing" do
      h = Harlock.Test.start_app(SizeApp, self(), rows: 24, cols: 80)
      Harlock.Test.resize(h, 24, 80)

      state = :sys.get_state(h.runtime)
      assert {state.rows, state.cols} == {24, 80}

      Harlock.Test.stop(h)
    end
  end
end
