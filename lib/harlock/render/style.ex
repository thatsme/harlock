defmodule Harlock.Render.Style do
  @moduledoc """
  Visual attributes for a rendered cell.

      %Harlock.Render.Style{fg: :cyan, bold: true}
      %Harlock.Render.Style{reverse: true}
      %Harlock.Render.Style{bg: {:rgb, 30, 30, 40}}

  Fields:

    * `:fg` / `:bg` — foreground / background colour. Atoms for the 16
      standard colours (`:red`, `:bright_blue`, …), `{:color256, n}` for
      256-color, `{:rgb, r, g, b}` for truecolor, or `:default` for
      "no override."
    * `:bold` / `:dim` / `:italic` / `:underline` / `:reverse` — boolean
      attributes, all `false` by default.

  Construct with the struct directly, or with `from/1` for keyword/map
  input. `merge/2` layers one style on top of another — useful for
  applying a theme `:focus` token to a user-set element style without
  losing fg/bg.

  Compared by value, hashed by value — used as a key into the renderer's
  internal style table.
  """

  defstruct fg: :default,
            bg: :default,
            bold: false,
            italic: false,
            underline: false,
            dim: false,
            reverse: false

  @type color ::
          :default
          | :black
          | :red
          | :green
          | :yellow
          | :blue
          | :magenta
          | :cyan
          | :white
          | :bright_black
          | :bright_red
          | :bright_green
          | :bright_yellow
          | :bright_blue
          | :bright_magenta
          | :bright_cyan
          | :bright_white
          | {:color256, 0..255}
          | {:rgb, 0..255, 0..255, 0..255}

  @type t :: %__MODULE__{
          fg: color(),
          bg: color(),
          bold: boolean(),
          italic: boolean(),
          underline: boolean(),
          dim: boolean(),
          reverse: boolean()
        }

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @spec from(keyword() | map() | t()) :: t()
  def from(%__MODULE__{} = s), do: s
  def from(opts) when is_list(opts), do: struct!(__MODULE__, opts)
  def from(opts) when is_map(opts), do: struct!(__MODULE__, opts)

  @doc """
  Layer `over` on top of `under`. Non-default colors in `over` win;
  boolean attributes OR (any `true` wins). Used to apply theme tokens on
  top of element-provided styles without losing user-set fg/bg.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = under, %__MODULE__{} = over) do
    %__MODULE__{
      fg: if(over.fg == :default, do: under.fg, else: over.fg),
      bg: if(over.bg == :default, do: under.bg, else: over.bg),
      bold: over.bold or under.bold,
      italic: over.italic or under.italic,
      underline: over.underline or under.underline,
      dim: over.dim or under.dim,
      reverse: over.reverse or under.reverse
    }
  end

  @doc """
  Emit an SGR escape sequence that fully sets the cell's attributes. Starts
  with `\\e[0m` so the previous style doesn't bleed through. The diff renderer
  emits this once per style transition; we don't try to be clever about
  diffing individual attribute changes — terminals process SGR fast enough
  that the extra bytes are cheaper than the bookkeeping.

  Reads the active terminal color depth from `Harlock.Terminal.Caps.get/0`
  (process-dict) and downgrades colors that the terminal can't display:

    * `:mono` — fg/bg become `:default` (no color SGR emitted)
    * `:ansi16` — `{:rgb, …}` and `{:color256, …}` collapse to the
      nearest standard ANSI color
    * `:ansi256` — `{:rgb, …}` collapses into the 256-color cube
    * `:truecolor` — colors pass through unchanged

  When no caps are installed (e.g. tests rendering through the test
  backend) the default is `:truecolor`, matching v0.3 behaviour exactly.
  """
  alias Harlock.Terminal.Caps

  @spec to_sgr(t()) :: iodata()
  def to_sgr(%__MODULE__{} = s) do
    depth = Caps.color_depth()
    fg = downgrade(s.fg, depth)
    bg = downgrade(s.bg, depth)

    params =
      ["0"]
      |> append_if(s.bold, "1")
      |> append_if(s.dim, "2")
      |> append_if(s.italic, "3")
      |> append_if(s.underline, "4")
      |> append_if(s.reverse, "7")
      |> append_color(:fg, fg)
      |> append_color(:bg, bg)

    ["\e[", Enum.intersperse(Enum.reverse(params), ?;), ?m]
  end

  @doc """
  Map a color to what the given terminal depth can actually emit.
  Exposed for tests; the renderer uses it implicitly via `to_sgr/1`.
  """
  @spec downgrade(color(), Caps.color_depth()) :: color()
  def downgrade(:default, _depth), do: :default
  def downgrade(_color, :mono), do: :default
  def downgrade(color, :truecolor), do: color

  def downgrade({:rgb, r, g, b}, :ansi256), do: {:color256, rgb_to_256(r, g, b)}
  def downgrade({:rgb, r, g, b}, :ansi16), do: rgb_to_ansi16(r, g, b)
  def downgrade({:color256, n}, :ansi16), do: color256_to_ansi16(n)
  def downgrade(color, :ansi256), do: color
  def downgrade(color, :ansi16), do: color

  # 6x6x6 color cube starting at 16; 0..5 per channel.
  defp rgb_to_256(r, g, b) do
    16 + 36 * scale_to_6(r) + 6 * scale_to_6(g) + scale_to_6(b)
  end

  defp scale_to_6(c) when c < 48, do: 0
  defp scale_to_6(c) when c < 115, do: 1
  defp scale_to_6(c), do: div(c - 35, 40) |> min(5)

  # 256-color → standard ANSI 16: low 16 pass through to their bright
  # variants where appropriate; cube/grayscale map via approximate RGB
  # then through the RGB→16 path.
  defp color256_to_ansi16(n) when n in 0..7, do: ansi16_basic(n)
  defp color256_to_ansi16(n) when n in 8..15, do: ansi16_bright(n - 8)

  defp color256_to_ansi16(n) when n in 16..231 do
    idx = n - 16
    r = div(idx, 36) * 51
    g = rem(div(idx, 6), 6) * 51
    b = rem(idx, 6) * 51
    rgb_to_ansi16(r, g, b)
  end

  defp color256_to_ansi16(n) when n in 232..255 do
    level = (n - 232) * 10 + 8
    rgb_to_ansi16(level, level, level)
  end

  defp ansi16_basic(0), do: :black
  defp ansi16_basic(1), do: :red
  defp ansi16_basic(2), do: :green
  defp ansi16_basic(3), do: :yellow
  defp ansi16_basic(4), do: :blue
  defp ansi16_basic(5), do: :magenta
  defp ansi16_basic(6), do: :cyan
  defp ansi16_basic(7), do: :white

  defp ansi16_bright(0), do: :bright_black
  defp ansi16_bright(1), do: :bright_red
  defp ansi16_bright(2), do: :bright_green
  defp ansi16_bright(3), do: :bright_yellow
  defp ansi16_bright(4), do: :bright_blue
  defp ansi16_bright(5), do: :bright_magenta
  defp ansi16_bright(6), do: :bright_cyan
  defp ansi16_bright(7), do: :bright_white

  # RGB → nearest ANSI 16. Channel bit if > 127; bright variant if any
  # channel ≥ 192. Grays handled separately so they don't all collapse
  # to :black.
  defp rgb_to_ansi16(r, g, b) do
    max_c = max(r, max(g, b))
    min_c = min(r, min(g, b))
    gray? = max_c - min_c < 24
    bright? = max_c >= 192

    cond do
      gray? and max_c < 48 -> :black
      gray? and max_c < 128 -> :bright_black
      gray? and max_c < 192 -> :white
      gray? -> :bright_white
      true -> chromatic_ansi16(r, g, b, bright?)
    end
  end

  @chromatic_by_bits %{
    0 => :black,
    1 => :red,
    2 => :green,
    3 => :yellow,
    4 => :blue,
    5 => :magenta,
    6 => :cyan,
    7 => :white
  }

  defp chromatic_ansi16(r, g, b, bright?) do
    bits = channel_bit(r) + 2 * channel_bit(g) + 4 * channel_bit(b)
    base = Map.fetch!(@chromatic_by_bits, bits)
    if bright?, do: brighten(base), else: base
  end

  defp channel_bit(c) when c > 127, do: 1
  defp channel_bit(_), do: 0

  defp brighten(:black), do: :bright_black
  defp brighten(:red), do: :bright_red
  defp brighten(:green), do: :bright_green
  defp brighten(:yellow), do: :bright_yellow
  defp brighten(:blue), do: :bright_blue
  defp brighten(:magenta), do: :bright_magenta
  defp brighten(:cyan), do: :bright_cyan
  defp brighten(:white), do: :bright_white

  defp append_if(params, false, _val), do: params
  defp append_if(params, true, val), do: [val | params]

  defp append_color(params, _which, :default), do: params

  defp append_color(params, which, color) do
    Enum.reduce(color_codes(which, color), params, &[&1 | &2])
  end

  @standard_fg %{
    black: "30",
    red: "31",
    green: "32",
    yellow: "33",
    blue: "34",
    magenta: "35",
    cyan: "36",
    white: "37"
  }

  @bright_fg %{
    bright_black: "90",
    bright_red: "91",
    bright_green: "92",
    bright_yellow: "93",
    bright_blue: "94",
    bright_magenta: "95",
    bright_cyan: "96",
    bright_white: "97"
  }

  defp color_codes(which, color) do
    cond do
      color == :default ->
        []

      is_atom(color) and Map.has_key?(@standard_fg, color) ->
        [shift(@standard_fg[color], which)]

      is_atom(color) and Map.has_key?(@bright_fg, color) ->
        [shift(@bright_fg[color], which)]

      match?({:color256, _}, color) ->
        {:color256, n} = color
        [base256(which), "5", Integer.to_string(n)]

      match?({:rgb, _, _, _}, color) ->
        {:rgb, r, g, b} = color

        [
          base256(which),
          "2",
          Integer.to_string(r),
          Integer.to_string(g),
          Integer.to_string(b)
        ]
    end
  end

  defp shift("3" <> rest, :bg), do: "4" <> rest
  defp shift("9" <> rest, :bg), do: "10" <> rest
  defp shift(code, :fg), do: code

  defp base256(:fg), do: "38"
  defp base256(:bg), do: "48"
end
