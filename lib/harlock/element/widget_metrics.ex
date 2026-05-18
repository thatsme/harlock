defmodule Harlock.Element.WidgetMetrics do
  @moduledoc false
  # Process-dictionary scratchpad that lets the renderer hand layout-time
  # facts (e.g. a viewport's rendered visible height) back to the runtime,
  # which then uses them for R2 widget-key auto-routing.
  #
  # Mirrors the pattern already used by Harlock.Focus and Harlock.Theme:
  # the runtime calls `clear/0` before rendering, the renderer calls
  # `record_viewport/2` whenever it draws a focusable viewport, and the
  # runtime calls `consume/0` afterward to drain the map onto state.

  @key :harlock_widget_metrics

  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end

  @spec record_viewport(any(), non_neg_integer()) :: :ok
  def record_viewport(focus_id, viewport_h) when not is_nil(focus_id) do
    metrics = Process.get(@key, %{})
    Process.put(@key, Map.put(metrics, focus_id, %{viewport_h: viewport_h}))
    :ok
  end

  def record_viewport(_nil_id, _h), do: :ok

  @spec consume() :: %{any() => %{viewport_h: non_neg_integer()}}
  def consume do
    metrics = Process.get(@key, %{})
    Process.delete(@key)
    metrics
  end
end
