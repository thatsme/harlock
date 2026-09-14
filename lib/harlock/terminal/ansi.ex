defmodule Harlock.Terminal.Ansi do
  @moduledoc false

  @esc "\e"
  @csi @esc <> "["

  # xterm mouse reporting: 1000 presses and releases (and the wheel), 1002 motion
  # while a button is held, 1006 the SGR encoding the parser reads, which has
  # no column limit. 1003, motion with no button held, is left off: it reports
  # every cell the pointer crosses.
  @mouse_on [@csi <> "?1000h", @csi <> "?1002h", @csi <> "?1006h"]
  @mouse_off [@csi <> "?1006l", @csi <> "?1002l", @csi <> "?1000l"]

  @doc """
  Sequence written immediately after opening the tty in raw mode.
  `mouse: true` also turns on mouse reporting.
  """
  def enter(opts \\ []) do
    [
      @csi <> "?1049h",
      @csi <> "?25l",
      @csi <> "?2004h",
      @csi <> "2J",
      @csi <> "H"
    ] ++ if(Keyword.get(opts, :mouse, false), do: @mouse_on, else: [])
  end

  @doc """
  Sequence written before restoring termios and closing the tty. Always turns
  mouse reporting off, whether or not it was turned on: a terminal left
  reporting clicks after an app exits types escape sequences into the shell.
  """
  def leave do
    @mouse_off ++
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

  @doc "Show / hide the terminal cursor (DECTCEM)."
  def cursor_show, do: @csi <> "?25h"
  def cursor_hide, do: @csi <> "?25l"

  @doc "DA (primary device attributes) probe. Response begins with ESC [ ? ... c"
  def da, do: @csi <> "c"

  @doc "DA2 (secondary device attributes) probe."
  def da2, do: @csi <> ">c"

  @doc "Cursor position report request. Response is ESC [ <row> ; <col> R"
  def cpr, do: @csi <> "6n"
end
