defmodule Harlock.Render.StyleTest do
  use ExUnit.Case, async: true

  alias Harlock.Render.Style

  defp sgr(style), do: style |> Style.to_sgr() |> IO.iodata_to_binary()

  test "default style is just reset" do
    assert sgr(%Style{}) == "\e[0m"
  end

  test "attributes are appended in order" do
    assert sgr(%Style{bold: true}) == "\e[0;1m"
    assert sgr(%Style{italic: true, underline: true}) == "\e[0;3;4m"
    assert sgr(%Style{dim: true, reverse: true}) == "\e[0;2;7m"
  end

  test "standard 8-color fg" do
    assert sgr(%Style{fg: :red}) == "\e[0;31m"
    assert sgr(%Style{fg: :white}) == "\e[0;37m"
  end

  test "standard 8-color bg shifts 30→40" do
    assert sgr(%Style{bg: :blue}) == "\e[0;44m"
  end

  test "bright 8-color fg uses 90s" do
    assert sgr(%Style{fg: :bright_cyan}) == "\e[0;96m"
  end

  test "bright 8-color bg shifts 90→100" do
    assert sgr(%Style{bg: :bright_red}) == "\e[0;101m"
  end

  test "256-color fg and bg" do
    assert sgr(%Style{fg: {:color256, 196}}) == "\e[0;38;5;196m"
    assert sgr(%Style{bg: {:color256, 17}}) == "\e[0;48;5;17m"
  end

  test "truecolor fg and bg" do
    assert sgr(%Style{fg: {:rgb, 255, 128, 0}}) == "\e[0;38;2;255;128;0m"
    assert sgr(%Style{bg: {:rgb, 12, 34, 56}}) == "\e[0;48;2;12;34;56m"
  end

  test "default color is omitted" do
    assert sgr(%Style{fg: :default, bg: :default, bold: true}) == "\e[0;1m"
  end

  test "Style.from/1 accepts keyword and map" do
    assert Style.from(bold: true).bold == true
    assert Style.from(%{bold: true}).bold == true
    assert Style.from(%Style{bold: true}).bold == true
  end
end
