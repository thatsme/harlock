defmodule Harlock.IO.Test.Writer do
  @moduledoc false
  # In-memory writer for tests. Implements the same message contract as
  # Terminal.Writer ({:write, iodata} casts), but instead of pushing bytes
  # to a tty, it interprets them against a cell buffer that the test API
  # can inspect.
  #
  # The interpreter is small: it tracks (cursor_row, cursor_col) and writes
  # codepoints into the buffer at the current cursor position, advancing
  # rightward. CSI move (`\e[<r>;<c>H`) repositions the cursor. SGR codes
  # set the current style. Everything else is dropped silently — diff output
  # is well-formed by construction.

  use GenServer

  alias Harlock.Render.Buffer
  alias Harlock.Render.Cell
  alias Harlock.Render.Style
  alias Harlock.Render.StyleTable
  alias Harlock.Width

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec set_size(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def set_size(server, rows, cols), do: GenServer.call(server, {:set_size, rows, cols})

  @spec buffer(GenServer.server()) :: Buffer.t()
  def buffer(server), do: GenServer.call(server, :buffer)

  @spec to_string(GenServer.server()) :: String.t()
  def to_string(server), do: GenServer.call(server, :to_string)

  @spec raw_writes(GenServer.server()) :: binary()
  def raw_writes(server), do: GenServer.call(server, :raw_writes)

  @impl true
  def init(opts) do
    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)

    {:ok,
     %{
       rows: rows,
       cols: cols,
       buffer: Buffer.new(rows, cols),
       styles: StyleTable.new(),
       cursor: {0, 0},
       style: %Style{},
       raw: []
     }}
  end

  @impl true
  def handle_cast({:write, data}, state) do
    bin = data |> IO.iodata_to_binary()
    state = %{state | raw: [bin | state.raw]}
    {:noreply, interpret(bin, state)}
  end

  @impl true
  def handle_call({:set_size, rows, cols}, _from, state) do
    state = %{
      state
      | rows: rows,
        cols: cols,
        buffer: Buffer.new(rows, cols),
        styles: StyleTable.new(),
        cursor: {0, 0}
    }

    {:reply, :ok, state}
  end

  def handle_call(:buffer, _from, state), do: {:reply, state.buffer, state}

  def handle_call(:to_string, _from, state),
    do: {:reply, buffer_to_string(state.buffer), state}

  def handle_call(:raw_writes, _from, state) do
    {:reply, state.raw |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  # -- Byte stream interpreter ----------------------------------------------

  defp interpret(<<>>, state), do: state

  defp interpret(<<"\e[", rest::binary>>, state) do
    case take_csi(rest, <<>>) do
      {:ok, params, final, remaining} ->
        interpret(remaining, apply_csi(state, params, final))

      :incomplete ->
        state
    end
  end

  defp interpret(<<cp::utf8, rest::binary>>, state) do
    interpret(rest, put_char(state, cp))
  end

  defp interpret(<<_::8, rest::binary>>, state), do: interpret(rest, state)

  defp take_csi(<<>>, _acc), do: :incomplete

  defp take_csi(<<c, rest::binary>>, acc) when c in 0x40..0x7E,
    do: {:ok, acc, c, rest}

  defp take_csi(<<c, rest::binary>>, acc) when c in 0x20..0x3F,
    do: take_csi(rest, acc <> <<c>>)

  defp take_csi(_, _), do: :incomplete

  # CSI <r>;<c>H — move cursor (1-indexed). Convert to 0-indexed.
  defp apply_csi(state, params, ?H) do
    {row, col} = parse_two_int_params(params, 1, 1)
    %{state | cursor: {max(0, row - 1), max(0, col - 1)}}
  end

  # CSI 2J — clear screen
  defp apply_csi(state, "2", ?J) do
    %{state | buffer: Buffer.new(state.rows, state.cols), cursor: {0, 0}}
  end

  # CSI m — SGR (set graphic rendition). We map the most common params.
  defp apply_csi(state, params, ?m) do
    %{state | style: parse_sgr(params, state.style)}
  end

  defp apply_csi(state, _params, _final), do: state

  defp parse_two_int_params(<<>>, default_a, default_b), do: {default_a, default_b}

  defp parse_two_int_params(params, default_a, default_b) do
    case String.split(params, ";") do
      [a, b] -> {parse_int_or(a, default_a), parse_int_or(b, default_b)}
      [a] -> {parse_int_or(a, default_a), default_b}
      _ -> {default_a, default_b}
    end
  end

  defp parse_int_or("", default), do: default

  defp parse_int_or(str, default) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp parse_sgr("", _style), do: %Style{}
  defp parse_sgr("0", _style), do: %Style{}

  defp parse_sgr(params, style) do
    params
    |> String.split(";")
    |> apply_sgr_codes(style)
  end

  defp apply_sgr_codes([], style), do: style

  defp apply_sgr_codes([code | rest], style) do
    {style, rest} = apply_sgr_code(style, code, rest)
    apply_sgr_codes(rest, style)
  end

  defp apply_sgr_code(_style, "0", rest), do: {%Style{}, rest}
  defp apply_sgr_code(style, "1", rest), do: {%{style | bold: true}, rest}
  defp apply_sgr_code(style, "2", rest), do: {%{style | dim: true}, rest}
  defp apply_sgr_code(style, "3", rest), do: {%{style | italic: true}, rest}
  defp apply_sgr_code(style, "4", rest), do: {%{style | underline: true}, rest}
  defp apply_sgr_code(style, "7", rest), do: {%{style | reverse: true}, rest}

  defp apply_sgr_code(style, code, rest) when code in ~w(30 31 32 33 34 35 36 37) do
    {%{style | fg: standard_color(code, 30)}, rest}
  end

  defp apply_sgr_code(style, code, rest) when code in ~w(40 41 42 43 44 45 46 47) do
    {%{style | bg: standard_color(code, 40)}, rest}
  end

  defp apply_sgr_code(style, code, rest) when code in ~w(90 91 92 93 94 95 96 97) do
    {%{style | fg: bright_color(code, 90)}, rest}
  end

  defp apply_sgr_code(style, "38", ["5", n | rest]) do
    {%{style | fg: {:color256, parse_int_or(n, 0)}}, rest}
  end

  defp apply_sgr_code(style, "38", ["2", r, g, b | rest]) do
    {%{style | fg: {:rgb, parse_int_or(r, 0), parse_int_or(g, 0), parse_int_or(b, 0)}}, rest}
  end

  defp apply_sgr_code(style, "48", ["5", n | rest]) do
    {%{style | bg: {:color256, parse_int_or(n, 0)}}, rest}
  end

  defp apply_sgr_code(style, _code, rest), do: {style, rest}

  defp standard_color(code, base) do
    [:black, :red, :green, :yellow, :blue, :magenta, :cyan, :white]
    |> Enum.at(parse_int_or(code, base) - base)
  end

  defp bright_color(code, base) do
    [
      :bright_black,
      :bright_red,
      :bright_green,
      :bright_yellow,
      :bright_blue,
      :bright_magenta,
      :bright_cyan,
      :bright_white
    ]
    |> Enum.at(parse_int_or(code, base) - base)
  end

  defp put_char(state, cp) do
    {row, col} = state.cursor

    if in_bounds?(state, row, col) do
      {style_id, styles} = StyleTable.intern(state.styles, state.style)
      w = Width.width(<<cp::utf8>>)

      buffer =
        state.buffer
        |> Buffer.put(row, col, Cell.new(cp, style_id))
        |> maybe_continuation(row, col, w, state.cols, style_id)

      %{state | buffer: buffer, styles: styles, cursor: {row, col + max(1, w)}}
    else
      state
    end
  end

  defp maybe_continuation(buffer, row, col, 2, cols, style_id) when col + 1 < cols do
    Buffer.put(buffer, row, col + 1, Cell.new(:continuation, style_id))
  end

  defp maybe_continuation(buffer, _row, _col, _w, _cols, _style_id), do: buffer

  defp in_bounds?(%{rows: rows, cols: cols}, row, col),
    do: row >= 0 and row < rows and col >= 0 and col < cols

  defp buffer_to_string(%Buffer{rows: rows, cols: cols} = buf) do
    for row <- 0..(rows - 1)//1 do
      for col <- 0..(cols - 1)//1 do
        cell_char(Buffer.get(buf, row, col).char)
      end
      |> Enum.reject(&is_nil/1)
      |> :unicode.characters_to_binary()
    end
    |> Enum.join("\n")
  end

  defp cell_char(nil), do: ?\s
  defp cell_char(:continuation), do: nil
  defp cell_char(cp) when is_integer(cp), do: cp
  defp cell_char(bin) when is_binary(bin), do: bin
end
