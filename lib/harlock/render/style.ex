defmodule Harlock.Render.Style do
  @moduledoc false
  # Visual attributes for a cell. Compared by value, hashed by value — used as
  # a key into StyleTable. Keep the shape stable: adding fields is a breaking
  # change for any consumer that pattern-matches.

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
  Emit an SGR escape sequence that fully sets the cell's attributes. Starts
  with `\\e[0m` so the previous style doesn't bleed through. The diff renderer
  emits this once per style transition; we don't try to be clever about
  diffing individual attribute changes — terminals process SGR fast enough
  that the extra bytes are cheaper than the bookkeeping.
  """
  @spec to_sgr(t()) :: iodata()
  def to_sgr(%__MODULE__{} = s) do
    params =
      ["0"]
      |> append_if(s.bold, "1")
      |> append_if(s.dim, "2")
      |> append_if(s.italic, "3")
      |> append_if(s.underline, "4")
      |> append_if(s.reverse, "7")
      |> append_color(:fg, s.fg)
      |> append_color(:bg, s.bg)

    ["\e[", Enum.intersperse(Enum.reverse(params), ?;), ?m]
  end

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
