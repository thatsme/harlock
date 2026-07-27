defmodule Harlock.Bench do
  @moduledoc """
  Frame-timing harness for element trees.

  Two costs make up a frame: turning an element tree into a `Frame`, and diffing
  two frames into the ANSI bytes that transition between them. This measures
  both, over a set of scenarios that can be re-run to catch regressions.

  It is deliberately public rather than a dev-only script, because the more
  useful question is usually about *your* view rather than Harlock's:

      iex> Harlock.Bench.render(my_view(model), rows: 50, cols: 120) |> Harlock.Bench.format()

  ## Reading the numbers

  Results report percentiles, not just a mean. A frame budget is about the slow
  frames — a 60 Hz target has ~16 000µs to spend, and a p99 that blows it is
  visible stutter even when the mean looks fine. Means also hide the GC pauses
  and scheduler hops that percentiles expose.

  Timings come from `:timer.tc/1`, so they include whatever else the VM was doing.
  Comparisons between runs on one machine are meaningful; absolute numbers across
  machines are not.

  Rendering here is pure — no terminal, no IO, no `Writer`. Turning the diff's
  iodata into bytes and writing it is a separate cost this does not measure.
  """

  alias Harlock.Element
  alias Harlock.Element.Renderer
  alias Harlock.Layout.Rect
  alias Harlock.Render.Diff

  @default_rows 200
  @default_cols 80
  @default_samples 100
  @default_warmup 20

  @typedoc "Microsecond timings for one measured operation."
  @type stats :: %{
          samples: pos_integer(),
          min: non_neg_integer(),
          p50: non_neg_integer(),
          p95: non_neg_integer(),
          p99: non_neg_integer(),
          max: non_neg_integer(),
          mean: non_neg_integer()
        }

  @doc """
  Time a zero-arity function.

  Options: `:samples` (default #{@default_samples}) and `:warmup` (default
  #{@default_warmup}). Warmup runs are discarded — the first few passes over cold
  code and caches are not representative of a steady-state frame.
  """
  @spec measure((-> any()), keyword()) :: stats()
  def measure(fun, opts \\ []) when is_function(fun, 0) do
    samples = Keyword.get(opts, :samples, @default_samples)
    warmup = Keyword.get(opts, :warmup, @default_warmup)

    for _ <- 1..warmup//1, do: fun.()

    1..samples//1
    |> Enum.map(fn _ -> fun |> :timer.tc() |> elem(0) end)
    |> stats()
  end

  @doc """
  Time rendering an element tree into a frame.

  Options: `:rows` (default #{@default_rows}), `:cols` (default #{@default_cols}),
  plus anything `measure/2` takes.
  """
  @spec render(Element.t(), keyword()) :: stats()
  def render(%Element{} = element, opts \\ []) do
    {rows, cols} = dimensions(opts)
    measure(fn -> Renderer.render(element, rows, cols) end, opts)
  end

  @doc """
  Time rendering a *different* tree on each sample.

  Necessary wherever a cache sits behind the thing being measured. `render/2`
  hands the same tree over and over, so any memo keyed on content hits from the
  second sample onward and the result describes a steady-state redraw of
  unchanged content. That is a real case — but it is not the one a user typing
  into a textarea experiences, where every keystroke changes the value and misses.

  `build` receives the sample number and returns the tree for it. It is called
  *outside* the timed section, and each tree becomes garbage as soon as its
  sample finishes — holding a list of large variants alive instead adds GC
  pressure that inflates every reading. That mistake overstated this measurement
  by more than a factor of two the first time it was written.

      Bench.render_varying(&Bench.scenario(:textarea_wrapped, n: 200, edit: &1), samples: 50)
  """
  @spec render_varying((pos_integer() -> Element.t()), keyword()) :: stats()
  def render_varying(build, opts \\ []) when is_function(build, 1) do
    {rows, cols} = dimensions(opts)
    samples = Keyword.get(opts, :samples, @default_samples)
    warmup = Keyword.get(opts, :warmup, @default_warmup)

    for i <- 1..warmup//1, do: Renderer.render(build.(i), rows, cols)

    1..samples//1
    |> Enum.map(fn i ->
      element = build.(i)
      {micros, _frame} = :timer.tc(fn -> Renderer.render(element, rows, cols) end)
      micros
    end)
    |> stats()
  end

  @doc """
  Build one scenario by name.

  `:n` scales the content. `:edit` perturbs it, which is what makes each tree
  distinct for `render_varying/2` — a content-keyed cache has to miss for the
  measurement to describe editing rather than redrawing.
  """
  @spec scenario(atom(), keyword()) :: Element.t()
  def scenario(name, opts \\ []) do
    n = Keyword.get(opts, :n, @default_rows)
    edit = Keyword.get(opts, :edit, 0)

    case name do
      :text_rows -> text_rows(n)
      :nested_boxes -> nested_boxes(24)
      :table_rows -> table_rows(n)
      :textarea_wrapped -> textarea_wrapped(n, edit)
      :tree_expanded -> tree_expanded(n)
    end
  end

  @doc """
  Time diffing the frames produced by two element trees.

  Both trees are rendered once up front, so this measures only the diff. Pass the
  same tree twice to measure the no-change path, which is the common case for a
  dirty-flag runtime and should be cheap.
  """
  @spec diff(Element.t(), Element.t(), keyword()) :: stats()
  def diff(%Element{} = before_el, %Element{} = after_el, opts \\ []) do
    {rows, cols} = dimensions(opts)
    prev = Renderer.render(before_el, rows, cols)
    next = Renderer.render(after_el, rows, cols)

    measure(fn -> Diff.diff(prev, next) end, opts)
  end

  @doc """
  Canonical scenarios, as `{name, element}` pairs.

  These exist so a baseline is reproducible rather than ad hoc. `:n` scales the
  data-heavy ones (default 200, matching the default row count so the content
  slightly overflows the screen — the interesting case, since it exercises
  clipping).
  """
  @spec scenarios(keyword()) :: [{atom(), Element.t()}]
  def scenarios(opts \\ []) do
    for name <- [:text_rows, :nested_boxes, :table_rows, :textarea_wrapped, :tree_expanded],
        do: {name, scenario(name, opts)}
  end

  @doc """
  Render every scenario and return `{name, stats}` pairs.

  `:textarea_wrapped` is the one to watch: every render rewraps the whole value,
  which is the cost the roadmap's incremental-rewrap work exists to remove. A
  baseline here is what makes that change measurable rather than assumed.
  """
  @spec run(keyword()) :: [{atom(), stats()}]
  def run(opts \\ []) do
    Enum.map(scenarios(opts), fn {name, element} -> {name, render(element, opts)} end)
  end

  @doc "Format `stats/0` or a list of `{name, stats}` pairs as an aligned table."
  @spec format(stats() | [{atom(), stats()}]) :: String.t()
  def format(%{samples: _} = stats), do: format([{:measured, stats}])

  def format(results) when is_list(results) do
    header =
      pad("scenario", 18) <>
        pad("min", 9) <> pad("p50", 9) <> pad("p95", 9) <> pad("p99", 9) <> pad("max", 9)

    rows =
      Enum.map_join(results, "\n", fn {name, s} ->
        pad(to_string(name), 18) <>
          pad(us(s.min), 9) <>
          pad(us(s.p50), 9) <> pad(us(s.p95), 9) <> pad(us(s.p99), 9) <> pad(us(s.max), 9)
      end)

    header <> "\n" <> String.duplicate("-", 63) <> "\n" <> rows
  end

  # -- internals -------------------------------------------------------------

  defp dimensions(opts) do
    {Keyword.get(opts, :rows, @default_rows), Keyword.get(opts, :cols, @default_cols)}
  end

  defp stats([]), do: %{samples: 0, min: 0, p50: 0, p95: 0, p99: 0, max: 0, mean: 0}

  defp stats(times) do
    sorted = Enum.sort(times)
    count = length(sorted)

    %{
      samples: count,
      min: List.first(sorted),
      p50: percentile(sorted, count, 50),
      p95: percentile(sorted, count, 95),
      p99: percentile(sorted, count, 99),
      max: List.last(sorted),
      mean: div(Enum.sum(sorted), count)
    }
  end

  # Nearest-rank on the sorted sample. Not interpolated: for a hundred-odd
  # samples of a noisy measurement, interpolation implies precision that is not
  # there.
  defp percentile(sorted, count, p) do
    index = (p / 100 * count) |> ceil() |> max(1) |> min(count)
    Enum.at(sorted, index - 1)
  end

  defp pad(text, width), do: String.pad_trailing(text, width)
  defp us(n), do: "#{n}µs"

  # -- scenarios -------------------------------------------------------------

  defp text_rows(n) do
    %Element{
      type: :vbox,
      opts: [constraints: List.duplicate({:length, 1}, n)],
      children: for(i <- 1..n, do: text_el("row #{i} of #{n} with some content"))
    }
  end

  # Layout solving is recursive, so depth costs separately from breadth.
  defp nested_boxes(depth) do
    Enum.reduce(1..depth, text_el("innermost"), fn i, inner ->
      %Element{
        type: :box,
        opts: [title: "level #{i}", border: :single, padding: 0],
        children: [inner]
      }
    end)
  end

  defp table_rows(n) do
    %Element{
      type: :table,
      opts: [
        columns: [
          %Harlock.Element.Column{title: "id", width: {:length, 6}, render: &to_string(&1.id)},
          %Harlock.Element.Column{title: "name", width: {:fill, 1}, render: & &1.name},
          %Harlock.Element.Column{title: "state", width: {:length, 10}, render: & &1.state}
        ],
        rows: for(i <- 1..n, do: %{id: i, name: "item #{i}", state: "running"}),
        row_id: & &1.id,
        focused_row: div(n, 2),
        selection: {:single, div(n, 2)}
      ],
      children: []
    }
  end

  defp textarea_wrapped(n, edit) do
    value =
      1..n
      |> Enum.map_join("\n", fn i ->
        "paragraph #{i} " <>
          String.duplicate("with enough words to wrap at eighty columns ", 2) <>
          if(i == 1 and edit > 0, do: String.duplicate("x", edit), else: "")
      end)

    %Element{
      type: :textarea,
      opts: [value: value, cursor: div(String.length(value), 2), wrap: true, focusable: :body],
      children: []
    }
  end

  defp tree_expanded(n) do
    # Ten children per branch, so the projection walks depth as well as breadth.
    branches = max(div(n, 10), 1)

    nodes =
      for b <- 1..branches do
        %{
          id: {:branch, b},
          label: "branch #{b}",
          children:
            for(c <- 1..10, do: %{id: {:leaf, b, c}, label: "leaf #{b}.#{c}", children: []})
        }
      end

    %Element{
      type: :tree,
      opts: [
        nodes: nodes,
        expanded: MapSet.new(for b <- 1..branches, do: {:branch, b}),
        focused: {:branch, 1}
      ],
      children: []
    }
  end

  defp text_el(content), do: %Element{type: :text, opts: [content: content], children: []}

  # Kept so a caller can sanity-check that a scenario fills the region it is
  # given rather than silently rendering nothing.
  @doc false
  @spec region(keyword()) :: Rect.t()
  def region(opts \\ []) do
    {rows, cols} = dimensions(opts)
    Rect.new(0, 0, cols, rows)
  end
end
