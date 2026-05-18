defmodule Harlock.Theme do
  @moduledoc """
  Visual theme tokens used by the renderer.

  v0.2 shipped the minimum surface the renderer actually reads
  (`:header`, `:focus`, `:selection`, `:border`). v0.4 adds the
  general-purpose tokens app authors reach for —
  `:primary`, `:accent`, `:muted`, `:error` — and ships three built-in
  themes plus caps-aware color downgrade so the same theme renders
  reasonably on truecolor, 256-color, 16-color, and monochrome
  terminals.

  Tokens (each a `Harlock.Render.Style.t()`):

    * `:header` — table column headers. Default: `bold: true`.
    * `:focus`  — active focus indicator. Default: `reverse: true`.
    * `:selection` — selected rows / cells. Default: `bg: :cyan`.
    * `:border` — default box border style. Default: `%Style{}` (no fg/bg).
    * `:primary` — primary brand / accent surface. Default: `fg: :cyan`.
    * `:accent` — secondary accent. Default: `fg: :magenta`.
    * `:muted`   — de-emphasised text. Default: `dim: true`.
    * `:error`   — error / destructive surface. Default: `fg: :red`.

  ## Setting a theme

      Harlock.run(MyApp, init_arg, theme: %Harlock.Theme{
        focus:     %Style{reverse: true, fg: :yellow},
        selection: %Style{bg: :blue, fg: :white}
      })

      # Or use a built-in:
      Harlock.run(MyApp, init_arg, theme: Harlock.Theme.builtin(:dark))

  Omitting the option uses `Harlock.Theme.default/0`, which matches the
  pre-theming hard-coded values byte-for-byte. The default theme is
  intentionally minimal — apps that want a visible identity pick a
  built-in or build their own.

  ## Built-in themes

    * `:default` — what v0.3 produced. Minimal, terminal-native colors.
    * `:dark` — opinionated dark palette suitable for cave-dwellers.
    * `:high_contrast` — bright primaries / strong borders, biased for
      readability over aesthetics.

  Look up with `Harlock.Theme.builtin/1`.

  ## Reading inside a callback

      def view(model) do
        accent = Harlock.Theme.get(:primary)
        text("hello", style: accent)
      end

  The runtime stashes the theme in the process dictionary before
  invoking `update/2` and `view/1`, mirroring the `Harlock.Focus` pattern.
  Don't call `get/1` outside a Harlock callback — there's nothing in the
  dictionary.
  """

  alias Harlock.Render.Style

  @key :harlock_theme

  @typedoc "A theme is the bag of styled tokens the renderer looks up."
  @type token ::
          :header
          | :focus
          | :selection
          | :border
          | :primary
          | :accent
          | :muted
          | :error

  @type t :: %__MODULE__{
          header: Style.t(),
          focus: Style.t(),
          selection: Style.t(),
          border: Style.t(),
          primary: Style.t(),
          accent: Style.t(),
          muted: Style.t(),
          error: Style.t()
        }

  defstruct header: %Style{bold: true},
            focus: %Style{reverse: true},
            selection: %Style{bg: :cyan},
            border: %Style{},
            primary: %Style{fg: :cyan},
            accent: %Style{fg: :magenta},
            muted: %Style{dim: true},
            error: %Style{fg: :red}

  @doc """
  The default theme. Matches the pre-theming hard-coded values exactly so
  apps without a custom theme render byte-identically across v0.3 and
  v0.4. New v0.4 tokens (`:primary`/`:accent`/`:muted`/`:error`) carry
  sensible defaults but are not read by the renderer itself — they're
  available only to apps that explicitly opt in via `get/1`.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @valid_tokens [:header, :focus, :selection, :border, :primary, :accent, :muted, :error]

  @doc """
  Build a theme from a keyword list or a map. Unspecified tokens take
  their default values.
  """
  @spec build(keyword() | map() | t()) :: t()
  def build(%__MODULE__{} = theme), do: theme
  def build(opts) when is_list(opts), do: struct!(__MODULE__, opts)
  def build(opts) when is_map(opts), do: struct!(__MODULE__, opts)

  @doc """
  Return one of the built-in themes by name. Available: `:default`,
  `:dark`, `:high_contrast`.
  """
  @spec builtin(:default | :dark | :high_contrast) :: t()
  def builtin(:default), do: default()

  def builtin(:dark) do
    %__MODULE__{
      header: %Style{bold: true, fg: :bright_white},
      focus: %Style{reverse: true, fg: :bright_yellow},
      selection: %Style{bg: :blue, fg: :bright_white},
      border: %Style{fg: :bright_black},
      primary: %Style{fg: :bright_cyan},
      accent: %Style{fg: :bright_magenta},
      muted: %Style{fg: :bright_black},
      error: %Style{fg: :bright_red, bold: true}
    }
  end

  def builtin(:high_contrast) do
    %__MODULE__{
      header: %Style{bold: true, fg: :white, bg: :black},
      focus: %Style{reverse: true, bold: true},
      selection: %Style{bg: :yellow, fg: :black, bold: true},
      border: %Style{fg: :white, bold: true},
      primary: %Style{fg: :white, bold: true},
      accent: %Style{fg: :bright_yellow, bold: true},
      muted: %Style{fg: :white},
      error: %Style{fg: :bright_red, bold: true, underline: true}
    }
  end

  @doc """
  Look up a theme token. Returns the value from the theme installed by
  the runtime, or the default if no theme is in scope.
  """
  @spec get(token()) :: Style.t()
  def get(token) when token in @valid_tokens do
    theme = Process.get(@key) || default()
    Map.fetch!(theme, token)
  end

  @doc false
  # Runtime stashes the theme before invoking user callbacks.
  def __set__(%__MODULE__{} = theme), do: Process.put(@key, theme)
  def __set__(nil), do: Process.delete(@key)

  @doc false
  def __clear__, do: Process.delete(@key)
end
