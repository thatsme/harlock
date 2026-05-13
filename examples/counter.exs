# Run with:
#   ./scripts/run.sh counter
#
# Or from iex:
#   iex -S mix
#   iex> c "examples/counter.exs"
#   iex> Harlock.run(Counter)

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

# If running via `mix run examples/counter.exs` (rather than loading via iex),
# kick off the app immediately.
case System.argv() do
  ["--run"] -> Harlock.run(Counter)
  _ -> :ok
end
