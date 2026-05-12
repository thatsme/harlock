defmodule Harlock.Element.Column do
  @moduledoc false
  # A single column spec for the `table` element.
  #
  #   * `:title` — header label (used only when `show_header: true`)
  #   * `:width` — a layout constraint: {:length, n} | {:percentage, p} |
  #     {:fill, w} | {:min, n} | {:max, n}
  #   * `:align` — :left | :right | :center
  #   * `:render` — fn(row) -> String.t() | iodata(). Defaults to
  #     `to_string/1` of the row itself, which is what makes `list`
  #     (a degenerate single-column table) ergonomic.

  defstruct title: "", width: {:fill, 1}, align: :left, render: nil

  @type t :: %__MODULE__{
          title: String.t(),
          width: Harlock.Layout.constraint(),
          align: :left | :right | :center,
          render: (any() -> String.t() | iodata()) | nil
        }

  @spec render_value(t(), any()) :: String.t()
  def render_value(%__MODULE__{render: nil}, row), do: stringify(row)
  def render_value(%__MODULE__{render: fun}, row), do: stringify(fun.(row))

  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_list(v), do: IO.iodata_to_binary(v)
  defp stringify(v), do: to_string(v)
end
