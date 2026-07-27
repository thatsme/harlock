defmodule Harlock.LayoutPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Harlock.Layout
  alias Harlock.Layout.Rect

  # The layout solver is the oldest load-bearing code in the tree and has a
  # genuinely mathematical contract, which makes it the one place where
  # generated input finds things example tests cannot: the invariants have to
  # hold for *every* constraint list, not the handful anyone thinks to write.
  #
  # Over-constrained input logs a warning by design, so these capture logs
  # rather than let thousands of them drown the suite.

  @moduletag :capture_log

  defp constraint do
    one_of([
      tuple({constant(:length), integer(0..40)}),
      tuple({constant(:percentage), integer(0..100)}),
      tuple({constant(:min), integer(0..40)}),
      tuple({constant(:max), integer(0..40)}),
      tuple({constant(:fill), integer(1..5)})
    ])
  end

  defp constraints, do: list_of(constraint(), max_length: 8)

  defp direction, do: one_of([constant(:vertical), constant(:horizontal)])

  defp region do
    gen all(w <- integer(0..120), h <- integer(0..60)) do
      Rect.new(0, 0, w, h)
    end
  end

  defp sizes(rects, :vertical), do: Enum.map(rects, & &1.h)
  defp sizes(rects, :horizontal), do: Enum.map(rects, & &1.w)

  defp available(%Rect{h: h}, :vertical), do: h
  defp available(%Rect{w: w}, :horizontal), do: w

  property "every slot gets a non-negative size" do
    check all(r <- region(), d <- direction(), cs <- constraints()) do
      for size <- Layout.split(r, d, cs) |> sizes(d) do
        assert size >= 0
      end
    end
  end

  property "one rect out per constraint in" do
    check all(r <- region(), d <- direction(), cs <- constraints()) do
      assert length(Layout.split(r, d, cs)) == length(cs)
    end
  end

  property "sizes never sum to more than the space available" do
    check all(r <- region(), d <- direction(), cs <- constraints()) do
      total = Layout.split(r, d, cs) |> sizes(d) |> Enum.sum()

      assert total <= available(r, d)
    end
  end

  property "a split with no :max cap and room to fit consumes the whole region" do
    # Leftover is absorbed rather than left as a gap — but only when nothing
    # forbids growing. A bound `:max` legitimately leaves space unused: filling it
    # would violate the cap the caller asked for. Found by this property, which
    # originally asserted the unconditional version and was wrong.
    uncapped =
      one_of([
        tuple({constant(:length), integer(0..10)}),
        tuple({constant(:min), integer(0..10)}),
        tuple({constant(:fill), integer(1..4)})
      ])

    check all(
            cs <- list_of(uncapped, min_length: 1, max_length: 6),
            slack <- integer(0..30),
            d <- direction()
          ) do
      # Sized so the lower bounds always fit, since over-constraining truncates.
      lower = Enum.sum(for c <- cs, do: lower_of(c))
      r = rect_for(d, lower + slack)

      total = Layout.split(r, d, cs) |> sizes(d) |> Enum.sum()

      assert total == available(r, d)
    end
  end

  # :percentage is excluded above because its lower bound depends on the total,
  # which is what this property is choosing — a circularity, not a solver issue.
  defp lower_of({:length, n}), do: n
  defp lower_of({:min, n}), do: n
  defp lower_of({:fill, _w}), do: 0

  property "slots are contiguous and non-overlapping" do
    check all(r <- region(), d <- direction(), cs <- constraints()) do
      rects = Layout.split(r, d, cs)

      {starts, lengths} =
        case d do
          :vertical -> {Enum.map(rects, & &1.row), Enum.map(rects, & &1.h)}
          :horizontal -> {Enum.map(rects, & &1.col), Enum.map(rects, & &1.w)}
        end

      # Each slot starts where the previous one ended; the first starts at the
      # region's own origin. An empty constraint list yields no slots at all.
      expected =
        case lengths do
          [] -> []
          _ -> [base(r, d) | lengths |> Enum.scan(base(r, d), &(&1 + &2)) |> Enum.drop(-1)]
        end

      assert starts == expected
    end
  end

  property "the cross axis is left untouched" do
    check all(r <- region(), d <- direction(), cs <- constraints()) do
      for rect <- Layout.split(r, d, cs) do
        case d do
          :vertical ->
            assert rect.col == r.col
            assert rect.w == r.w

          :horizontal ->
            assert rect.row == r.row
            assert rect.h == r.h
        end
      end
    end
  end

  property "a :max constraint is never exceeded" do
    check all(
            r <- region(),
            d <- direction(),
            caps <- list_of(integer(0..30), min_length: 1, max_length: 6)
          ) do
      cs = Enum.map(caps, &{:max, &1})
      given = Layout.split(r, d, cs) |> sizes(d)

      for {size, cap} <- Enum.zip(given, caps) do
        assert size <= cap
      end
    end
  end

  property "a :length constraint is honoured when there is room for all of them" do
    check all(
            lengths <- list_of(integer(0..20), min_length: 1, max_length: 6),
            slack <- integer(0..20),
            d <- direction()
          ) do
      total = Enum.sum(lengths)
      r = rect_for(d, total + slack)
      cs = Enum.map(lengths, &{:length, &1})

      given = Layout.split(r, d, cs) |> sizes(d)

      # The last slot absorbs the slack, since nothing here is flexible.
      assert Enum.drop(given, -1) == Enum.drop(lengths, -1)
      assert List.last(given) == List.last(lengths) + slack
    end
  end

  property ":fill splits the remainder in proportion to its weights" do
    check all(
            weights <- list_of(integer(1..4), min_length: 2, max_length: 4),
            space <- integer(0..120),
            d <- direction()
          ) do
      cs = Enum.map(weights, &{:fill, &1})
      given = Layout.split(rect_for(d, space), d, cs) |> sizes(d)

      assert Enum.sum(given) == space

      # Round-off has to land somewhere, so proportionality is checked within a
      # cell per slot rather than exactly.
      weight_sum = Enum.sum(weights)

      for {size, weight} <- Enum.zip(given, weights) do
        ideal = space * weight / weight_sum
        assert_in_delta size, ideal, 1.0 + length(weights)
      end
    end
  end

  property "over-constraining truncates instead of crashing" do
    check all(
            lengths <- list_of(integer(1..30), min_length: 2, max_length: 8),
            d <- direction()
          ) do
      # Deliberately far less room than demanded.
      r = rect_for(d, div(Enum.sum(lengths), 4))
      cs = Enum.map(lengths, &{:length, &1})

      given = Layout.split(r, d, cs) |> sizes(d)

      assert length(given) == length(cs)
      assert Enum.all?(given, &(&1 >= 0))
      assert Enum.sum(given) <= available(r, d)
    end
  end

  property "a zero-sized region yields zero-sized slots" do
    check all(d <- direction(), cs <- constraints()) do
      given = Layout.split(rect_for(d, 0), d, cs) |> sizes(d)

      assert Enum.all?(given, &(&1 == 0))
    end
  end

  property "splitting is deterministic" do
    check all(r <- region(), d <- direction(), cs <- constraints()) do
      assert Layout.split(r, d, cs) == Layout.split(r, d, cs)
    end
  end

  defp base(%Rect{row: row}, :vertical), do: row
  defp base(%Rect{col: col}, :horizontal), do: col

  defp rect_for(:vertical, n), do: Rect.new(0, 0, 10, n)
  defp rect_for(:horizontal, n), do: Rect.new(0, 0, n, 10)
end
