defmodule Harlock.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/thatsme/harlock"

  def project do
    [
      app: :harlock,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      description: description(),
      package: package(),
      source_url: @source_url,
      homepage_url: @source_url,
      deps: deps(),
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    """
    A pure-Elixir TUI framework for Unix terminals. TEA-style model / update /
    view loop on top of OTP, with first-class focus traversal, layout
    constraints, ANSI cell-diff rendering, and a thin termios NIF for direct
    /dev/tty control.
    """
  end

  defp package do
    [
      maintainers: ["thatsme"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Roadmap" => "#{@source_url}/blob/main/ROADMAP.md"
      },
      # priv/ is created by the Makefile at install time, so it doesn't
      # need to ship in the tarball. examples/ ships so consumers can see
      # working apps via `mix hex.docs` or by browsing the package contents.
      files: ~w(
        lib
        c_src
        examples
        Makefile
        mix.exs
        README.md
        CHANGELOG.md
        ROADMAP.md
        LICENSE
        .formatter.exs
      )
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.2"},
      {:elixir_make, "~> 0.8", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "ROADMAP.md",
        "CHANGELOG.md",
        "LICENSE",
        "c_src/README.md": [filename: "termios_nif", title: "Termios NIF"]
      ],
      groups_for_modules: [
        Apps: [
          Harlock,
          Harlock.App,
          Harlock.Cmd,
          Harlock.Sub,
          Harlock.Focus,
          Harlock.Theme,
          Harlock.TextBuffer,
          Harlock.Elements,
          Harlock.Element.Column
        ],
        Testing: [
          Harlock.Test
        ],
        Rendering: [
          Harlock.Render.Style,
          Harlock.Width
        ]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end
end
