defmodule Harlock.Width do
  @moduledoc """
  Display-column width of strings and graphemes for terminal rendering.

  `String.length/1` counts graphemes, not columns. For ASCII the two are
  the same; for CJK, emoji, and combining marks they aren't. Use this
  module wherever a width is meant for cursor positioning, padding, or
  truncation against the terminal grid.

  Width rules (Unicode 15.1 East Asian Width + emoji presentation):

    * Control characters → 0
    * Combining marks, variation selectors, ZWJ, zero-width spaces → 0
    * East Asian Wide / Fullwidth → 2
    * Regional indicator pairs (flag emoji) → 2
    * Other emoji → 2 (we use coarse 0x1F000–0x1FAFF ranges; over-claim
      is safer than under-claim — alignment off by one column beats text
      bleeding into the next cell)
    * Everything else → 1

  The grapheme width is the maximum width of any codepoint in the cluster:
  combining marks attach at width 0 to a base of 1 or 2, so the cluster
  width equals the base width. ZWJ sequences (e.g. 👨‍👩‍👧) take the
  width of any wide codepoint in the cluster (terminals render them as one
  glyph, which is 2 cells; we accept that as the cluster width).
  """

  @typedoc "Width of a grapheme in terminal cells."
  @type cells :: 0 | 1 | 2

  @doc """
  Display width of a single grapheme. Returns 0 for empty input.
  """
  @spec width(String.t()) :: cells()
  def width(""), do: 0

  def width(grapheme) when is_binary(grapheme) do
    case String.to_charlist(grapheme) do
      [a, b] when a in 0x1F1E6..0x1F1FF and b in 0x1F1E6..0x1F1FF ->
        2

      codepoints ->
        codepoints
        |> Enum.map(&codepoint_width/1)
        |> Enum.max(fn -> 0 end)
    end
  end

  @doc """
  Total display width of a string — the sum of its grapheme widths.
  """
  @spec string_width(String.t()) :: non_neg_integer()
  def string_width(str) when is_binary(str) do
    str
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + width(g) end)
  end

  @doc """
  Truncate a string to at most `max_cols` display columns. A wide grapheme
  that wouldn't fit entirely in the remaining budget is dropped, not split.
  """
  @spec slice(String.t(), non_neg_integer()) :: String.t()
  def slice(_str, 0), do: ""

  def slice(str, max_cols) when is_binary(str) and max_cols > 0 do
    {acc, _w} =
      str
      |> String.graphemes()
      |> Enum.reduce_while({[], 0}, fn g, {acc, w} ->
        gw = width(g)

        if w + gw > max_cols do
          {:halt, {acc, w}}
        else
          {:cont, {[g | acc], w + gw}}
        end
      end)

    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  @doc """
  Pad a string on the right with `pad` so its display width equals
  `target_cols`. Returns the original string unchanged if it's already
  wider than the target.
  """
  @spec pad_trailing(String.t(), non_neg_integer(), String.t()) :: String.t()
  def pad_trailing(str, target_cols, pad \\ " ") when is_binary(str) do
    diff = target_cols - string_width(str)

    if diff > 0 do
      str <> String.duplicate(pad, diff)
    else
      str
    end
  end

  @doc """
  Pad a string on the left with `pad` so its display width equals
  `target_cols`. Returns the original string unchanged if it's already
  wider than the target.
  """
  @spec pad_leading(String.t(), non_neg_integer(), String.t()) :: String.t()
  def pad_leading(str, target_cols, pad \\ " ") when is_binary(str) do
    diff = target_cols - string_width(str)

    if diff > 0 do
      String.duplicate(pad, diff) <> str
    else
      str
    end
  end

  # ---- codepoint width tables --------------------------------------------

  # Zero-width: control chars, combining marks, format chars, ZWJ/VS.
  defp codepoint_width(cp) when cp < 0x20, do: 0
  defp codepoint_width(cp) when cp in 0x7F..0x9F, do: 0
  defp codepoint_width(cp) when cp in 0x0300..0x036F, do: 0
  defp codepoint_width(cp) when cp in 0x0483..0x0489, do: 0
  defp codepoint_width(cp) when cp in 0x0591..0x05BD, do: 0
  defp codepoint_width(0x05BF), do: 0
  defp codepoint_width(cp) when cp in 0x05C1..0x05C2, do: 0
  defp codepoint_width(cp) when cp in 0x05C4..0x05C5, do: 0
  defp codepoint_width(0x05C7), do: 0
  defp codepoint_width(cp) when cp in 0x0610..0x061A, do: 0
  defp codepoint_width(cp) when cp in 0x064B..0x065F, do: 0
  defp codepoint_width(0x0670), do: 0
  defp codepoint_width(cp) when cp in 0x06D6..0x06DC, do: 0
  defp codepoint_width(cp) when cp in 0x06DF..0x06E4, do: 0
  defp codepoint_width(cp) when cp in 0x06E7..0x06E8, do: 0
  defp codepoint_width(cp) when cp in 0x06EA..0x06ED, do: 0
  defp codepoint_width(0x0711), do: 0
  defp codepoint_width(cp) when cp in 0x0730..0x074A, do: 0
  defp codepoint_width(cp) when cp in 0x07A6..0x07B0, do: 0
  defp codepoint_width(cp) when cp in 0x07EB..0x07F3, do: 0
  defp codepoint_width(cp) when cp in 0x0816..0x0819, do: 0
  defp codepoint_width(cp) when cp in 0x081B..0x0823, do: 0
  defp codepoint_width(cp) when cp in 0x0825..0x0827, do: 0
  defp codepoint_width(cp) when cp in 0x0829..0x082D, do: 0
  defp codepoint_width(cp) when cp in 0x0859..0x085B, do: 0
  defp codepoint_width(cp) when cp in 0x08D3..0x08E1, do: 0
  defp codepoint_width(cp) when cp in 0x08E3..0x0902, do: 0
  defp codepoint_width(cp) when cp in 0x093A..0x093A, do: 0
  defp codepoint_width(cp) when cp in 0x093C..0x093C, do: 0
  defp codepoint_width(cp) when cp in 0x0941..0x0948, do: 0
  defp codepoint_width(0x094D), do: 0
  defp codepoint_width(cp) when cp in 0x0951..0x0957, do: 0
  defp codepoint_width(cp) when cp in 0x0962..0x0963, do: 0
  defp codepoint_width(cp) when cp in 0x1AB0..0x1AFF, do: 0
  defp codepoint_width(cp) when cp in 0x1DC0..0x1DFF, do: 0
  # Zero-width space, ZWNJ, ZWJ, bidi, word joiner
  defp codepoint_width(cp) when cp in 0x200B..0x200F, do: 0
  defp codepoint_width(cp) when cp in 0x202A..0x202E, do: 0
  defp codepoint_width(cp) when cp in 0x2060..0x2064, do: 0
  defp codepoint_width(cp) when cp in 0x2066..0x206F, do: 0
  defp codepoint_width(cp) when cp in 0x20D0..0x20FF, do: 0
  # Variation selectors + combining half marks
  defp codepoint_width(cp) when cp in 0xFE00..0xFE0F, do: 0
  defp codepoint_width(cp) when cp in 0xFE20..0xFE2F, do: 0
  defp codepoint_width(0xFEFF), do: 0
  defp codepoint_width(cp) when cp in 0xE0100..0xE01EF, do: 0

  # Wide ranges (East Asian Wide + Fullwidth + emoji).
  defp codepoint_width(cp) when cp in 0x1100..0x115F, do: 2
  defp codepoint_width(0x2329), do: 2
  defp codepoint_width(0x232A), do: 2
  defp codepoint_width(cp) when cp in 0x2E80..0x303E, do: 2
  defp codepoint_width(cp) when cp in 0x3041..0x33FF, do: 2
  defp codepoint_width(cp) when cp in 0x3400..0x4DBF, do: 2
  defp codepoint_width(cp) when cp in 0x4E00..0x9FFF, do: 2
  defp codepoint_width(cp) when cp in 0xA000..0xA4CF, do: 2
  defp codepoint_width(cp) when cp in 0xA960..0xA97F, do: 2
  defp codepoint_width(cp) when cp in 0xAC00..0xD7A3, do: 2
  defp codepoint_width(cp) when cp in 0xF900..0xFAFF, do: 2
  defp codepoint_width(cp) when cp in 0xFE10..0xFE19, do: 2
  defp codepoint_width(cp) when cp in 0xFE30..0xFE6F, do: 2
  defp codepoint_width(cp) when cp in 0xFF00..0xFF60, do: 2
  defp codepoint_width(cp) when cp in 0xFFE0..0xFFE6, do: 2
  defp codepoint_width(cp) when cp in 0x16FE0..0x16FF1, do: 2
  defp codepoint_width(cp) when cp in 0x17000..0x18D08, do: 2
  defp codepoint_width(cp) when cp in 0x1AFF0..0x1B2FB, do: 2
  defp codepoint_width(cp) when cp in 0x1F000..0x1FAFF, do: 2
  defp codepoint_width(cp) when cp in 0x20000..0x2FFFD, do: 2
  defp codepoint_width(cp) when cp in 0x30000..0x3FFFD, do: 2

  defp codepoint_width(_), do: 1
end
