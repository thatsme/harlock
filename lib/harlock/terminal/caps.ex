defmodule Harlock.Terminal.Caps do
  @moduledoc false
  # Terminal capability detection. Called once as a function from the
  # AppSupervisor's init/1, result threaded into Writer/Reader as start args.
  #
  # v0.1 is env-only: $TERM, $TERM_PROGRAM, $COLORTERM. DA/DA2 escape probes
  # need an async-read-with-timeout primitive that :file.read does not give
  # us, so they wait for v0.2 when the reader switches to a port-based
  # implementation or we move probes to a stty min/time toggle.

  defstruct [
    :term,
    :term_program,
    :colorterm,
    :colors,
    :bracketed_paste,
    :mouse,
    :kitty_keyboard
  ]

  @type color_depth :: :mono | :ansi16 | :ansi256 | :truecolor

  @type t :: %__MODULE__{
          term: String.t(),
          term_program: String.t(),
          colorterm: String.t(),
          colors: color_depth(),
          bracketed_paste: boolean(),
          mouse: boolean(),
          kitty_keyboard: boolean()
        }

  @spec detect() :: t()
  def detect do
    term = System.get_env("TERM") || ""
    colorterm = System.get_env("COLORTERM") || ""
    term_program = System.get_env("TERM_PROGRAM") || ""

    %__MODULE__{
      term: term,
      term_program: term_program,
      colorterm: colorterm,
      colors: classify_colors(term, colorterm),
      bracketed_paste: supports_bracketed_paste?(term, term_program),
      mouse: supports_mouse?(term),
      kitty_keyboard: term_program == "kitty" or term == "xterm-kitty"
    }
  end

  defp classify_colors(_term, colorterm) when colorterm in ["truecolor", "24bit"], do: :truecolor

  defp classify_colors(term, _) do
    cond do
      term == "" -> :mono
      term in ["dumb"] -> :mono
      String.contains?(term, "256color") -> :ansi256
      String.contains?(term, "direct") -> :truecolor
      String.starts_with?(term, "xterm") -> :ansi16
      String.starts_with?(term, "screen") -> :ansi16
      String.starts_with?(term, "tmux") -> :ansi16
      String.starts_with?(term, "rxvt") -> :ansi16
      true -> :ansi16
    end
  end

  defp supports_bracketed_paste?(term, term_program) do
    term_program in ["iTerm.app", "WezTerm", "Alacritty", "vscode", "Apple_Terminal", "ghostty"] or
      String.starts_with?(term, "xterm") or
      String.starts_with?(term, "screen") or
      String.starts_with?(term, "tmux") or
      term == "xterm-kitty"
  end

  defp supports_mouse?(term) do
    # We enable mouse on startup regardless and tolerate non-response; this is
    # just a hint for the runtime about whether to bother.
    term != "" and term != "dumb"
  end
end
