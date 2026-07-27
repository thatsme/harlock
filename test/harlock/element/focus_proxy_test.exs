defmodule Harlock.Element.FocusProxyTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Element.Focusables
  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer
  alias Harlock.Render.StyleTable

  # The style of the box's top-left corner tells us whether the border rendered
  # focused or not, without depending on which glyph it is.
  defp corner_style(el, focused) do
    frame = Renderer.render(el, 6, 20, focused)
    cell = Buffer.get(frame.buffer, 0, 0)
    StyleTable.get(frame.styles, cell.style_id)
  end

  defp proxy_box do
    box(
      title: "Log",
      border: :rounded,
      border_style: [dim: true],
      focus_style: [fg: :cyan, bold: true],
      focus_proxy: :log,
      child: viewport(focusable: :log, offset: 0, content_height: 3, child: text("body"))
    )
  end

  describe "styling" do
    test "the border takes the focus style when the proxied child is focused" do
      focused = corner_style(proxy_box(), :log)

      assert focused.fg == :cyan
      assert focused.bold
    end

    test "the border stays unfocused when something else has focus" do
      unfocused = corner_style(proxy_box(), :other)

      assert unfocused.dim
      refute unfocused.fg == :cyan
    end

    test "no focus at all leaves the border alone" do
      assert corner_style(proxy_box(), nil).dim
    end

    test "a proxy for an id that is not focused anywhere is inert" do
      el = box(border_style: [dim: true], focus_proxy: :nonexistent, child: text("x"))
      assert corner_style(el, :log).dim
    end
  end

  describe "focus traversal" do
    test "a proxy box does not join the focus order" do
      {ids, _traps, _widgets} = Focusables.collect(proxy_box())

      # only the viewport is focusable; the box is invisible to Tab by
      # construction, since collection keys on :focusable alone
      assert ids == [:log]
    end

    test "a proxy box is not registered as a routable widget" do
      {_ids, _traps, widgets} = Focusables.collect(proxy_box())

      assert Map.keys(widgets) == [:log]
      assert widgets[:log].type == :viewport
    end
  end

  describe "precedence" do
    test ":focusable wins when both are set" do
      el =
        box(
          border_style: [dim: true],
          focus_style: [fg: :red],
          focusable: :self,
          focus_proxy: :other,
          child: text("x")
        )

      assert corner_style(el, :self).fg == :red
      # the proxied id does not light it up, because :focusable took precedence
      assert corner_style(el, :other).dim
    end
  end

  describe "default focus style" do
    test "without :focus_style the proxy still visibly changes the border" do
      el =
        box(
          border: :rounded,
          focus_proxy: :log,
          child: viewport(focusable: :log, offset: 0, content_height: 1, child: text("b"))
        )

      refute corner_style(el, :log) == corner_style(el, :other)
    end
  end
end
