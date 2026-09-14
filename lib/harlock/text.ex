defmodule Harlock.Text do
  @moduledoc """
  Styled, multi-line text content: the type `Harlock.Elements.text/2` accepts,
  and the functions that lay it out.

  Content is either a plain binary or a list of runs. A run is a binary, which
  takes the element's style, or `{binary, style}`, where `style` is anything
  `:style` accepts — a `%Harlock.Render.Style{}` or a keyword list:

      "plain"
      ["CPU ", {"92%", fg: :red, bold: true}, " of 8 cores"]

  A run's style is layered over the style it is drawn with using
  `Harlock.Render.Style.merge/2`: its colours win, and boolean attributes
  combine. So a focused `text` keeps its focus highlight while a red run inside
  it stays red.

  `"\\n"` always ends a line, in a plain binary as well as inside a run.

  ## Measuring

  `height/2` exists for `Harlock.Elements.viewport/1`, which takes the height of
  its content from the app. Wrapped text has no height until it is laid out at a
  width, so an app scrolling a wrapped paragraph asks for it:

      content_height: Harlock.Text.height(description, inner_width)
  """

  alias Harlock.Render.Style
  alias Harlock.TextArea
  alias Harlock.Width

  @typedoc "A piece of text, optionally with its own style."
  @type run :: String.t() | {String.t(), Style.t() | keyword()}

  @typedoc "What `text/2` accepts."
  @type t :: String.t() | [run()]

  @typedoc "A laid-out line: runs with their styles resolved against a base style."
  @type line :: [{String.t(), Style.t()}]

  @doc """
  Raise `ArgumentError` unless `content` is valid text content. Returns `content`.

  `text/2` calls this so a malformed run fails inside the app's `view/1`, where
  the stack trace points at it, rather than later inside the renderer.
  """
  @spec validate!(t()) :: t()
  def validate!(content) when is_binary(content), do: content

  def validate!(content) when is_list(content) do
    Enum.each(content, fn
      text when is_binary(text) ->
        :ok

      {text, %Style{}} when is_binary(text) ->
        :ok

      {text, style} when is_binary(text) and is_list(style) ->
        Style.from(style)

      other ->
        raise ArgumentError,
              "text content must be a binary or a list of binaries and " <>
                "{binary, style} tuples, got a run: #{inspect(other)}"
    end)

    content
  end

  def validate!(other) do
    raise ArgumentError,
          "text content must be a binary or a list of runs, got: #{inspect(other)}"
  end

  @doc """
  Lay `content` out as lines of styled runs.

  Options:
    * `:width` — wrap at this many display columns. `nil` (the default) splits
      only on `"\\n"`.
    * `:style` — the base style runs are merged over (default `%Style{}`).

  Wrapping is `Harlock.TextArea.wrap_line/2`'s: at the last space that fits,
  mid-word only when a word is wider than the line. The space a line breaks at
  is dropped, so alignment measures the visible text.
  """
  @spec lines(t(), keyword()) :: [line()]
  def lines(content, opts \\ []) do
    base = opts |> Keyword.get(:style, %Style{}) |> Style.from()
    width = Keyword.get(opts, :width)

    content
    |> hard_lines(base)
    |> Enum.flat_map(fn line -> wrap(line, width) end)
  end

  @doc """
  The number of rows `content` occupies when wrapped at `width` columns.

  Always at least 1 for non-empty content; `""` and `[]` are 0.
  """
  @spec height(t(), pos_integer()) :: non_neg_integer()
  def height(content, width) when is_integer(width) and width > 0 do
    if empty?(content), do: 0, else: content |> lines(width: width) |> length()
  end

  @doc "The display width of the widest line of `content`, unwrapped."
  @spec width(t()) :: non_neg_integer()
  def width(content) do
    content
    |> lines()
    |> Enum.map(&line_width/1)
    |> Enum.max(fn -> 0 end)
  end

  @doc "The display width of one laid-out line."
  @spec line_width(line()) :: non_neg_integer()
  def line_width(line),
    do: Enum.reduce(line, 0, fn {t, _}, acc -> acc + Width.string_width(t) end)

  @doc false
  @spec empty?(t()) :: boolean()
  def empty?(""), do: true
  def empty?([]), do: true
  def empty?(_), do: false

  # -- splitting on "\n" -----------------------------------------------------

  defp hard_lines(content, base) when is_binary(content),
    do: hard_lines([content], base)

  defp hard_lines(runs, base) do
    {lines, current} =
      Enum.reduce(runs, {[], []}, fn run, {lines, current} ->
        {text, style} = resolve(run, base)

        [first | rest] = String.split(text, "\n")
        current = push(current, first, style)

        Enum.reduce(rest, {lines, current}, fn piece, {ls, cur} ->
          {[Enum.reverse(cur) | ls], push([], piece, style)}
        end)
      end)

    Enum.reverse([Enum.reverse(current) | lines])
  end

  defp resolve(text, base) when is_binary(text), do: {text, base}
  defp resolve({text, style}, base), do: {text, Style.merge(base, Style.from(style))}

  defp push(current, "", _style), do: current
  defp push(current, text, style), do: [{text, style} | current]

  # -- wrapping --------------------------------------------------------------

  defp wrap(line, nil), do: [line]
  defp wrap([], _width), do: [[]]

  defp wrap(line, width) do
    plain = Enum.map_join(line, fn {t, _} -> t end)
    segments = TextArea.wrap_line(plain, width)
    last = length(segments) - 1

    {lines, _rest} =
      segments
      |> Enum.with_index()
      |> Enum.map_reduce(line, fn {segment, i}, remaining ->
        {taken, remaining} = take_graphemes(remaining, grapheme_count(segment), [])
        taken = if i < last, do: drop_break_space(taken), else: taken
        {taken, remaining}
      end)

    lines
  end

  defp grapheme_count(segment), do: segment |> String.graphemes() |> length()

  # Take `n` graphemes' worth of runs from the front, splitting a run that
  # straddles the boundary so each half keeps the run's style.
  defp take_graphemes(runs, 0, acc), do: {Enum.reverse(acc), runs}
  defp take_graphemes([], _n, acc), do: {Enum.reverse(acc), []}

  defp take_graphemes([{text, style} | rest], n, acc) do
    count = String.length(text)

    if count <= n do
      take_graphemes(rest, n - count, [{text, style} | acc])
    else
      {head, tail} = String.split_at(text, n)
      {Enum.reverse([{head, style} | acc]), [{tail, style} | rest]}
    end
  end

  # wrap_line keeps the space a line breaks at on the end of that line.
  defp drop_break_space(runs) do
    case Enum.reverse(runs) do
      [{text, style} | rest] ->
        case String.trim_trailing(text, " ") do
          ^text -> runs
          "" -> Enum.reverse(rest)
          trimmed -> Enum.reverse([{trimmed, style} | rest])
        end

      [] ->
        runs
    end
  end
end
