defmodule Harlock.Layout do
  @moduledoc """
  Ratatui-style constraint layout solver.

  Splits a region along a direction (`:vertical` splits height into rows,
  `:horizontal` splits width into cols) according to a list of constraints:

    * `{:length, n}` — exact `n` cells
    * `{:percentage, p}` — `p`% of the available space (rounded down)
    * `{:min, n}` — at least `n` cells (v0.2: behaves as `:length`)
    * `{:max, n}` — at most `n` cells (v0.2: behaves as `:length`)
    * `{:fill, weight}` — distributes remaining space proportional to weight

  Apps typically don't call this directly — `vbox/1` and `hbox/1` from
  `Harlock.Elements` take a `:constraints` opt and the renderer invokes
  the solver internally. This module exists in the public surface so
  the constraint shapes are documented and stable.

  When the constraints exceed the available space, sizes are truncated
  from the tail-most non-fill constraints first, and a warning is
  logged. The solver never crashes on over-constrained layouts.

  Round-off from percentages and fill divisions is absorbed by the last
  fill constraint (or by the last constraint if there are no fills), so
  the returned sizes always sum exactly to the requested total.
  """

  require Logger

  alias Harlock.Layout.Rect

  @type direction :: :vertical | :horizontal
  @type constraint ::
          {:length, non_neg_integer()}
          | {:percentage, non_neg_integer()}
          | {:min, non_neg_integer()}
          | {:max, non_neg_integer()}
          | {:fill, pos_integer()}

  @spec split(Rect.t(), direction(), [constraint()]) :: [Rect.t()]
  def split(%Rect{} = region, direction, constraints)
      when direction in [:vertical, :horizontal] do
    :ok = validate_constraints!(constraints)
    total = total_for(direction, region)
    sizes = solve(constraints, total)
    apply_sizes(region, direction, sizes)
  end

  # :min and :max are reserved in the type but not implemented yet. Raise
  # at use rather than silently fall through as :length, so callers get a
  # clear error instead of a subtly-wrong layout. Real flexible-with-bounds
  # solving lands in v0.3.
  defp validate_constraints!(constraints) do
    Enum.each(constraints, fn
      {:min, _} ->
        raise ArgumentError,
              "Harlock.Layout: :min is reserved but not implemented in v0.2. " <>
                "Use {:length, n} for a fixed size, or {:fill, weight} for flexible. " <>
                "Tracked for v0.3 — see ROADMAP.md."

      {:max, _} ->
        raise ArgumentError,
              "Harlock.Layout: :max is reserved but not implemented in v0.2. " <>
                "Use {:length, n} for a fixed size, or {:fill, weight} for flexible. " <>
                "Tracked for v0.3 — see ROADMAP.md."

      _ ->
        :ok
    end)

    :ok
  end

  defp total_for(:vertical, %Rect{h: h}), do: h
  defp total_for(:horizontal, %Rect{w: w}), do: w

  defp solve([], _total), do: []

  defp solve(constraints, total) do
    natural = Enum.map(constraints, &natural_size(&1, total))
    natural_sum = Enum.sum(natural)
    fill_weights = Enum.map(constraints, &fill_weight/1)
    fill_total = Enum.sum(fill_weights)

    cond do
      natural_sum > total ->
        warn_overflow(constraints, natural_sum, total)
        truncate(natural, natural_sum - total)

      natural_sum < total and fill_total > 0 ->
        distribute(natural, fill_weights, total - natural_sum, fill_total)

      natural_sum < total ->
        absorb_remainder(natural, total - natural_sum)

      true ->
        natural
    end
  end

  defp natural_size({:length, n}, _total), do: n
  defp natural_size({:min, n}, _total), do: n
  defp natural_size({:max, n}, _total), do: n
  defp natural_size({:percentage, p}, total), do: div(total * p, 100)
  defp natural_size({:fill, _w}, _total), do: 0

  defp fill_weight({:fill, w}), do: w
  defp fill_weight(_), do: 0

  defp distribute(natural, weights, remaining, fill_total) do
    # First pass: integer share for each fill constraint.
    initial_shares =
      Enum.map(weights, fn
        0 -> 0
        w -> div(remaining * w, fill_total)
      end)

    distributed_sum = Enum.sum(initial_shares)
    leftover = remaining - distributed_sum

    # Place the leftover on the last constraint with a weight (will be a fill
    # by construction). Guaranteed to exist because fill_total > 0.
    shares = add_leftover_to_last_fill(initial_shares, weights, leftover)

    Enum.zip_with(natural, shares, &(&1 + &2))
  end

  defp add_leftover_to_last_fill(shares, weights, leftover) do
    {result, _} =
      Enum.zip(shares, weights)
      |> Enum.reverse()
      |> Enum.map_reduce(leftover, fn
        {s, 0}, lo -> {s, lo}
        {s, _w}, lo when lo > 0 -> {s + lo, 0}
        {s, _w}, lo -> {s, lo}
      end)

    Enum.reverse(result)
  end

  defp absorb_remainder(natural, leftover) do
    # No fill constraints — pad the last entry. Avoids losing cells silently.
    List.update_at(natural, -1, &(&1 + leftover))
  end

  defp truncate(natural, deficit) do
    # Walk from the tail, subtract from each non-zero size until deficit
    # vanishes. Sizes can't go below zero.
    {result, _} =
      natural
      |> Enum.reverse()
      |> Enum.map_reduce(deficit, fn
        size, 0 -> {size, 0}
        size, d when size >= d -> {size - d, 0}
        size, d -> {0, d - size}
      end)

    Enum.reverse(result)
  end

  defp warn_overflow(constraints, requested, available) do
    Logger.warning(fn ->
      "Harlock.Layout: constraints want #{requested} cells in #{available}; truncating. " <>
        "Constraints: #{inspect(constraints)}"
    end)
  end

  defp apply_sizes(%Rect{row: row, col: col, w: w} = _region, :vertical, sizes) do
    {rects, _} =
      Enum.map_reduce(sizes, row, fn size, y ->
        {Rect.new(y, col, w, size), y + size}
      end)

    rects
  end

  defp apply_sizes(%Rect{row: row, col: col, h: h} = _region, :horizontal, sizes) do
    {rects, _} =
      Enum.map_reduce(sizes, col, fn size, x ->
        {Rect.new(row, x, size, h), x + size}
      end)

    rects
  end
end
