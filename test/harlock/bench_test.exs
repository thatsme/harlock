defmodule Harlock.BenchTest do
  use ExUnit.Case, async: true

  import Harlock.Elements

  alias Harlock.Bench
  alias Harlock.Element.Renderer
  alias Harlock.Render.Buffer

  # Tiny sample counts throughout: these tests check the harness, not the
  # performance of anything, and a real sample count would make the suite slow
  # for no information.
  @fast [samples: 3, warmup: 0]

  describe "measure/2" do
    test "returns ordered percentiles over the requested sample count" do
      s = Bench.measure(fn -> Enum.sum(1..100) end, samples: 25, warmup: 2)

      assert s.samples == 25
      assert s.min <= s.p50
      assert s.p50 <= s.p95
      assert s.p95 <= s.p99
      assert s.p99 <= s.max
      assert s.min <= s.mean and s.mean <= s.max
    end

    test "a single sample collapses to one value" do
      s = Bench.measure(fn -> :ok end, samples: 1, warmup: 0)

      assert s.samples == 1
      assert s.min == s.max
      assert s.p50 == s.min
      assert s.p99 == s.min
    end

    test "warmup runs are not counted" do
      counter = :counters.new(1, [])

      Bench.measure(fn -> :counters.add(counter, 1, 1) end, samples: 5, warmup: 7)

      # 12 invocations, 5 of them measured
      assert :counters.get(counter, 1) == 12
    end

    test "measures something slow as slower than something fast" do
      fast = Bench.measure(fn -> :ok end, samples: 5, warmup: 1)
      slow = Bench.measure(fn -> Process.sleep(2) end, samples: 5, warmup: 1)

      assert slow.p50 > fast.p50
    end
  end

  describe "render/2" do
    test "times a render at the requested dimensions" do
      s = Bench.render(text("hi"), Keyword.merge(@fast, rows: 5, cols: 20))
      assert s.samples == 3
    end

    test "a bigger tree costs more than a smaller one" do
      # Both sized to fit the region: over-constraining logs a truncation warning
      # per render, which would bury the suite's output in noise.
      opts = Keyword.merge(@fast, rows: 200, cols: 80)

      small = Bench.render(rows_of(20), opts)
      large = Bench.render(rows_of(200), opts)

      assert large.p50 > small.p50
    end
  end

  describe "diff/3" do
    test "times a diff between two rendered trees" do
      s = Bench.diff(rows_of(10), rows_of(10), @fast)
      assert s.samples == 3
    end

    test "diffing identical trees still costs something" do
      # worth pinning: there is no early-out for an unchanged frame, so the
      # comparison walks every cell. The runtime only diffs when dirty, but the
      # cost is real when it does.
      s = Bench.diff(rows_of(50), rows_of(50), @fast)
      assert s.min > 0
    end
  end

  describe "scenarios/1" do
    test "every scenario renders something non-blank" do
      for {name, element} <- Bench.scenarios(n: 12) do
        frame = Renderer.render(element, 24, 80)

        refute blank?(frame), "scenario #{name} rendered an empty frame"
      end
    end

    test ":n scales the data-heavy scenarios" do
      small = Bench.scenarios(n: 10)
      large = Bench.scenarios(n: 100)

      assert Keyword.keys(small) == Keyword.keys(large)
      refute small[:table_rows] == large[:table_rows]
    end
  end

  describe "run/1 and format/1" do
    test "run returns stats per scenario" do
      results = Bench.run(Keyword.merge(@fast, n: 8, rows: 24, cols: 80))

      assert Keyword.keys(results) == Keyword.keys(Bench.scenarios())
      assert Enum.all?(results, fn {_name, s} -> s.samples == 3 end)
    end

    test "format renders a table naming each scenario" do
      output =
        Keyword.merge(@fast, n: 8, rows: 24, cols: 80)
        |> Bench.run()
        |> Bench.format()

      assert output =~ "scenario"
      assert output =~ "p99"
      assert output =~ "textarea_wrapped"
    end

    test "format accepts a bare stats map" do
      output = Bench.measure(fn -> :ok end, @fast) |> Bench.format()
      assert output =~ "measured"
    end
  end

  defp rows_of(n) do
    vbox(
      constraints: List.duplicate({:length, 1}, n),
      children: for(i <- 1..n, do: text("row #{i}"))
    )
  end

  defp blank?(frame) do
    for(
      r <- 0..(frame.buffer.rows - 1),
      c <- 0..(frame.buffer.cols - 1),
      do: Buffer.get(frame.buffer, r, c).char
    )
    |> Enum.all?(&(&1 == nil or &1 == ?\s))
  end
end
