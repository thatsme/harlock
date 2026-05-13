defmodule Harlock.Layout do
  @moduledoc """
  Ratatui-style constraint layout solver.

  Splits a region along a direction (`:vertical` splits height into rows,
  `:horizontal` splits width into cols) according to a list of constraints:

    * `{:length, n}` — exactly `n` cells
    * `{:percentage, p}` — `p`% of the available space (rounded down)
    * `{:min, n}` — at least `n` cells; grows like a `{:fill, 1}` if there's
      room. Pair with `:fill` or other `:min` / `:max` slots to set a floor
      under what would otherwise be flexible.
    * `{:max, n}` — at most `n` cells; behaves like a `{:fill, 1}` capped at
      `n`. Combine with other fills to share remaining space without
      overflowing.
    * `{:fill, weight}` — distributes remaining space proportional to weight

  Apps typically don't call this directly — `vbox/1` and `hbox/1` from
  `Harlock.Elements` take a `:constraints` opt and the renderer invokes
  the solver internally. This module exists in the public surface so
  the constraint shapes are documented and stable.

  ## Solver

  1. Compute each slot's *lower bound* (`:length` and `:percentage` get
     their full size; `:min(n)` gets `n`; `:fill` and `:max` get 0).
     If the lower bounds already exceed the available space, truncate
     from the tail and log a warning — the over-constrained behavior is
     identical to v0.2.

  2. Distribute the remainder across flexible slots. `:fill(weight)`,
     `:min`, and `:max` all participate; `:fill` carries its declared
     weight, `:min` and `:max` carry weight 1. (Override by writing
     `{:fill, w}` if you want explicit weighting.)

  3. Check `:max` caps. Any slot exceeding its cap is clamped to the cap
     and frozen; the excess goes back into the remainder. Iterate until
     no new freezes happen or until we hit `length(constraints)` passes
     (which is the absolute upper bound — each pass either freezes ≥1
     slot or terminates).

  4. If `:max` caps leave space unallocated (e.g. `[{:max, 10}, {:max, 10}]`
     in a 30-cell region), the trailing region is simply not used —
     children don't overflow their caps to fill the space.

  Round-off from percentages and fill divisions is absorbed by the last
  flexible slot, so for over-fill-saturating layouts the returned sizes
  sum exactly to the requested total.
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
    total = total_for(direction, region)
    sizes = solve(constraints, total)
    apply_sizes(region, direction, sizes)
  end

  defp total_for(:vertical, %Rect{h: h}), do: h
  defp total_for(:horizontal, %Rect{w: w}), do: w

  defp solve([], _total), do: []

  defp solve(constraints, total) do
    lower = Enum.map(constraints, &lower_bound(&1, total))
    lower_sum = Enum.sum(lower)

    cond do
      lower_sum > total ->
        warn_overflow(constraints, lower_sum, total)
        truncate(lower, lower_sum - total)

      lower_sum == total ->
        lower

      true ->
        weights = Enum.map(constraints, &fill_weight/1)
        remaining = total - lower_sum

        if Enum.sum(weights) == 0 do
          # No flexible slots. Backward-compat: absorb leftover onto the
          # last slot so the layout still consumes the full region.
          absorb_remainder(lower, remaining)
        else
          caps = Enum.map(constraints, &cap/1)
          distribute_with_caps(lower, weights, caps, remaining, length(constraints))
        end
    end
  end

  defp lower_bound({:length, n}, _), do: n
  defp lower_bound({:percentage, p}, total), do: div(total * p, 100)
  defp lower_bound({:min, n}, _), do: n
  defp lower_bound({:max, _}, _), do: 0
  defp lower_bound({:fill, _}, _), do: 0

  defp fill_weight({:fill, w}), do: w
  defp fill_weight({:min, _}), do: 1
  defp fill_weight({:max, _}), do: 1
  defp fill_weight(_), do: 0

  defp cap({:max, n}), do: n
  defp cap(_), do: :infinity

  # Iterate distribution → cap-check → redistribute until converged.
  # `passes_left` upper-bounds at `length(constraints)`; each pass either
  # freezes ≥1 slot (reducing the active set) or terminates.

  defp distribute_with_caps(sizes, _weights, _caps, 0, _passes), do: sizes

  defp distribute_with_caps(sizes, weights, caps, remaining, passes_left) do
    active_total = Enum.sum(weights)

    cond do
      active_total == 0 ->
        # All flexible slots have hit a cap or were never flexible. Leave the
        # remainder unallocated by design — pushing past a cap would defeat
        # the purpose of `:max`. The trailing region simply isn't used.
        sizes

      passes_left == 0 ->
        # Genuine non-convergence (cap redistribution would have continued
        # but we exhausted our pass budget). Shouldn't be reachable in
        # practice — each pass freezes ≥1 slot or terminates, so the bound
        # is `length(constraints)`.
        Logger.warning(fn ->
          "Harlock.Layout: cap redistribution didn't converge; #{remaining} cells unallocated."
        end)

        sizes

      true ->
        shares = compute_shares(weights, remaining, active_total)
        {new_sizes, new_weights, clamp_excess} = apply_with_caps(sizes, shares, weights, caps)

        if clamp_excess == 0 do
          new_sizes
        else
          distribute_with_caps(new_sizes, new_weights, caps, clamp_excess, passes_left - 1)
        end
    end
  end

  defp compute_shares(weights, remaining, active_total) do
    raw =
      Enum.map(weights, fn
        0 -> 0
        w -> div(remaining * w, active_total)
      end)

    distributed = Enum.sum(raw)
    roundoff = remaining - distributed
    add_roundoff_to_last_active(raw, weights, roundoff)
  end

  defp add_roundoff_to_last_active(shares, _weights, 0), do: shares

  defp add_roundoff_to_last_active(shares, weights, roundoff) do
    case last_active_index(weights) do
      nil -> shares
      idx -> List.update_at(shares, idx, &(&1 + roundoff))
    end
  end

  defp last_active_index(weights) do
    weights
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {w, idx} when w > 0 -> idx
      _ -> nil
    end)
  end

  # Apply each slot's share to its size, clamping at `:max`. Frozen slots
  # (cap-hitters) drop their weight to 0 for subsequent passes.
  defp apply_with_caps(sizes, shares, weights, caps) do
    [sizes, shares, weights, caps]
    |> Enum.zip()
    |> Enum.reduce({[], [], 0}, fn {size, share, weight, cap}, {ss, ws, excess} ->
      new = size + share

      case cap do
        :infinity ->
          {[new | ss], [weight | ws], excess}

        max_n when new > max_n ->
          {[max_n | ss], [0 | ws], excess + (new - max_n)}

        _ ->
          {[new | ss], [weight | ws], excess}
      end
    end)
    |> then(fn {ss, ws, excess} -> {Enum.reverse(ss), Enum.reverse(ws), excess} end)
  end

  defp absorb_remainder(sizes, 0), do: sizes

  defp absorb_remainder(sizes, leftover) do
    List.update_at(sizes, -1, &(&1 + leftover))
  end

  defp truncate(sizes, deficit) do
    {result, _} =
      sizes
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
