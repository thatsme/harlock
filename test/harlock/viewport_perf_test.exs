defmodule Harlock.ViewportPerfTest do
  @moduledoc """
  Day-one perf guardrail per the viewport design memo: render-then-clip
  pays O(content_height × width) per frame regardless of how much is
  visible. Asserts a soft budget so we notice if it gets dramatically
  worse, but doesn't pin a precise number — runners differ.
  """

  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Renderer

  @tag :perf
  test "render 200-row × 80-col viewport in < 50ms" do
    rows =
      Enum.map(1..200, fn i ->
        text(String.pad_trailing("row #{i}", 80, "."))
      end)

    child = vbox(children: rows)

    viewport_el =
      viewport(child: child, offset: 0, content_height: 200)

    # Warm up.
    Renderer.render(viewport_el, 24, 80)

    {us, _frame} =
      :timer.tc(fn ->
        Renderer.render(viewport_el, 24, 80)
      end)

    ms = us / 1000

    assert ms < 50,
           "viewport render took #{Float.round(ms, 2)}ms — exceeds 50ms budget"
  end

  @tag :perf
  test "viewport with focused element scrolls into view without extra cost" do
    rows =
      Enum.map(0..199, fn i ->
        if i == 180 do
          text_input(value: "x", cursor: 1, focusable: :input)
        else
          text("row #{i}")
        end
      end)

    child = vbox(children: rows)
    viewport_el = viewport(child: child, offset: 0, content_height: 200)

    Renderer.render(viewport_el, 24, 80, :input)

    {us, _frame} =
      :timer.tc(fn ->
        Renderer.render(viewport_el, 24, 80, :input)
      end)

    ms = us / 1000

    assert ms < 60,
           "viewport+focus render took #{Float.round(ms, 2)}ms — exceeds 60ms budget"
  end
end
