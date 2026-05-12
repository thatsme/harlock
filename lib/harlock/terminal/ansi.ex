defmodule Harlock.Terminal.Ansi do
  @moduledoc false

  @esc "\e"
  @csi @esc <> "["

  @doc "Sequence written immediately after opening the tty in raw mode."
  def enter do
    [
      @csi <> "?1049h",
      @csi <> "?25l",
      @csi <> "?2004h",
      @csi <> "2J",
      @csi <> "H"
    ]
  end

  @doc "Sequence written before restoring termios and closing the tty."
  def leave do
    [
      @csi <> "?2004l",
      @csi <> "?25h",
      @csi <> "0m",
      @csi <> "?1049l"
    ]
  end

  @doc "Move cursor to a 0-indexed row/col. ANSI is 1-indexed, so we add 1."
  def move(row, col) when row >= 0 and col >= 0 do
    [@csi, Integer.to_string(row + 1), ?;, Integer.to_string(col + 1), ?H]
  end

  def clear_screen, do: @csi <> "2J"
  def home, do: @csi <> "H"
  def reset_sgr, do: @csi <> "0m"

  @doc "DA (primary device attributes) probe. Response begins with ESC [ ? ... c"
  def da, do: @csi <> "c"

  @doc "DA2 (secondary device attributes) probe."
  def da2, do: @csi <> ">c"

  @doc "Cursor position report request. Response is ESC [ <row> ; <col> R"
  def cpr, do: @csi <> "6n"
end
