# Run with:
#   ./scripts/run.sh counter
#
# or directly:
#   mix run examples/counter.exs --run
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes.

defmodule Counter do
  use Harlock.App

  def init(_), do: %{n: 0}

  def update({:key, {:char, ?+}, []}, m), do: %{m | n: m.n + 1}
  def update({:key, {:char, ?=}, []}, m), do: %{m | n: m.n + 1}
  def update({:key, {:char, ?-}, []}, m), do: %{m | n: max(0, m.n - 1)}
  def update({:key, {:char, ?q}, []}, _), do: :quit
  def update({:key, :escape, []}, _), do: :quit
  def update(_event, m), do: m

  def view(m) do
    box(
      title: "Harlock Counter",
      title_align: :center,
      border: :rounded,
      border_style: [fg: :cyan],
      padding: {1, 2},
      child:
        vbox(
          constraints: [fill: 1, length: 1, length: 1],
          children: [
            text("count: #{m.n}", style: [fg: :cyan, bold: true]),
            spacer(),
            text("[+/=] inc  [-] dec  [q/Esc] quit", style: [dim: true])
          ]
        )
    )
  end
end

# `--run` starts the app; without it the file only defines the module, which is
# how the smoke tests load it.
case System.argv() do
  ["--run"] -> Harlock.run(Counter)
  _ -> :ok
end
