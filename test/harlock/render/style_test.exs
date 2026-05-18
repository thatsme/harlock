defmodule Harlock.Render.StyleTest do
  use ExUnit.Case, async: false

  alias Harlock.Render.Style
  alias Harlock.Terminal.Caps

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

  describe "downgrade/2 (v0.4 caps-aware emission)" do
    test ":mono collapses any color to :default" do
      assert Style.downgrade(:red, :mono) == :default
      assert Style.downgrade({:rgb, 255, 0, 0}, :mono) == :default
      assert Style.downgrade({:color256, 196}, :mono) == :default
      assert Style.downgrade(:default, :mono) == :default
    end

    test ":truecolor passes everything through" do
      assert Style.downgrade(:red, :truecolor) == :red
      assert Style.downgrade({:rgb, 1, 2, 3}, :truecolor) == {:rgb, 1, 2, 3}
      assert Style.downgrade({:color256, 17}, :truecolor) == {:color256, 17}
    end

    test ":ansi256 maps RGB into the 6x6x6 cube" do
      # 0,0,0 → cube origin (16); 255,255,255 → far corner (231).
      assert Style.downgrade({:rgb, 0, 0, 0}, :ansi256) == {:color256, 16}
      assert Style.downgrade({:rgb, 255, 255, 255}, :ansi256) == {:color256, 231}
      # Pure red maxes the r-channel only.
      assert Style.downgrade({:rgb, 255, 0, 0}, :ansi256) == {:color256, 196}
    end

    test ":ansi256 leaves named and 256-indexed colors unchanged" do
      assert Style.downgrade(:bright_cyan, :ansi256) == :bright_cyan
      assert Style.downgrade({:color256, 99}, :ansi256) == {:color256, 99}
    end

    test ":ansi16 collapses RGB to a named ANSI color" do
      assert Style.downgrade({:rgb, 0, 0, 0}, :ansi16) == :black
      assert Style.downgrade({:rgb, 255, 0, 0}, :ansi16) == :bright_red
      assert Style.downgrade({:rgb, 0, 255, 0}, :ansi16) == :bright_green
      assert Style.downgrade({:rgb, 100, 100, 100}, :ansi16) == :bright_black
      assert Style.downgrade({:rgb, 255, 255, 255}, :ansi16) == :bright_white
    end

    test ":ansi16 maps the 256-color basic range to its atom equivalents" do
      assert Style.downgrade({:color256, 0}, :ansi16) == :black
      assert Style.downgrade({:color256, 7}, :ansi16) == :white
      assert Style.downgrade({:color256, 8}, :ansi16) == :bright_black
      assert Style.downgrade({:color256, 15}, :ansi16) == :bright_white
    end

    test ":ansi16 maps cube/grayscale 256 entries via approximate RGB" do
      # 196 in the cube is pure red (255,0,0) → :bright_red.
      assert Style.downgrade({:color256, 196}, :ansi16) == :bright_red
      # 240 is mid-grayscale (~88) → :bright_black.
      assert Style.downgrade({:color256, 240}, :ansi16) == :bright_black
    end
  end

  describe "to_sgr/1 with caps in process dict" do
    test "no caps installed = truecolor passthrough (back-compat)" do
      Caps.__clear__()
      assert sgr(%Style{fg: {:rgb, 10, 20, 30}}) == "\e[0;38;2;10;20;30m"
    end

    test ":mono caps strip all color, keep attributes" do
      Caps.__set__(%Caps{colors: :mono})

      assert sgr(%Style{fg: :red, bold: true}) == "\e[0;1m"
      assert sgr(%Style{fg: {:rgb, 255, 0, 0}, bg: :blue}) == "\e[0m"

      Caps.__clear__()
    end

    test ":ansi16 caps downgrade RGB into a named color SGR" do
      Caps.__set__(%Caps{colors: :ansi16})

      # {:rgb,255,0,0} downgrades to :bright_red → \e[0;91m
      assert sgr(%Style{fg: {:rgb, 255, 0, 0}}) == "\e[0;91m"

      Caps.__clear__()
    end

    test ":ansi256 caps downgrade RGB into the cube" do
      Caps.__set__(%Caps{colors: :ansi256})

      assert sgr(%Style{fg: {:rgb, 255, 0, 0}}) == "\e[0;38;5;196m"

      Caps.__clear__()
    end
  end
end
