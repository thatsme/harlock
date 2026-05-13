defmodule Harlock.Theme do
  @moduledoc """
  Visual theme tokens used by the renderer.

  v0.2 ships the minimum surface that the renderer actually reads today
  so that widgets shipping in v0.3 (`progress`, `tabs`, `statusbar`,
  `keybar`) aren't built against hard-coded values that need a sweep in
  v0.4. The full theming ergonomics — extra tokens like `:primary` /
  `:accent` / `:muted` / `:error`, built-in themes, truecolor downgrade —
  arrive in v0.4.

  Tokens (each a `Harlock.Render.Style.t()`):

    * `:header` — table column headers. Default: `bold: true`.
    * `:focus`  — active focus indicator. Default: `reverse: true`.
    * `:selection` — selected rows / cells. Default: `bg: :cyan`.
    * `:border` — default box border style. Default: `%Style{}` (no fg/bg).

  ## Setting a theme

      Harlock.run(MyApp, init_arg, theme: %Harlock.Theme{
        focus:     %Style{reverse: true, fg: :yellow},
        selection: %Style{bg: :blue, fg: :white}
      })

  Omitting the option uses `Harlock.Theme.default/0`, which matches the
  pre-theming hard-coded values byte-for-byte.

  ## Reading inside a callback

      def view(model) do
        accent = Harlock.Theme.get(:focus)
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
  @type token :: :header | :focus | :selection | :border

  @type t :: %__MODULE__{
          header: Style.t(),
          focus: Style.t(),
          selection: Style.t(),
          border: Style.t()
        }

  defstruct header: %Style{bold: true},
            focus: %Style{reverse: true},
            selection: %Style{bg: :cyan},
            border: %Style{}

  @doc """
  The default theme. Matches the pre-theming hard-coded values exactly so
  apps without a custom theme render byte-identically.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Build a theme from a keyword list or a map. Unspecified tokens take
  their default values.
  """
  @spec build(keyword() | map() | t()) :: t()
  def build(%__MODULE__{} = theme), do: theme
  def build(opts) when is_list(opts), do: struct!(__MODULE__, opts)
  def build(opts) when is_map(opts), do: struct!(__MODULE__, opts)

  @doc """
  Look up a theme token. Returns the value from the theme installed by
  the runtime, or the default if no theme is in scope.
  """
  @spec get(token()) :: Style.t()
  def get(token) when token in [:header, :focus, :selection, :border] do
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
