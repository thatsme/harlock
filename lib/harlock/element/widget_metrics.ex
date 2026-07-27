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

  @spec record(any(), map()) :: :ok
  def record(focus_id, metrics) when not is_nil(focus_id) and is_map(metrics) do
    all = Process.get(@key, %{})
    Process.put(@key, Map.update(all, focus_id, metrics, &Map.merge(&1, metrics)))
    :ok
  end

  def record(_nil_id, _metrics), do: :ok

  @spec record_viewport(any(), non_neg_integer()) :: :ok
  def record_viewport(focus_id, viewport_h), do: record(focus_id, %{viewport_h: viewport_h})

  @spec consume() :: %{any() => map()}
  def consume do
    metrics = Process.get(@key, %{})
    Process.delete(@key)
    metrics
  end
end
