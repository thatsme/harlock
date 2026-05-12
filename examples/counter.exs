# Run with:
#   docker compose run --rm dev iex -S mix
#   iex> c "examples/counter.exs"
#   iex> Harlock.run(Counter)
#
# Or, in an interactive PowerShell with this image:
#   docker compose run --rm dev sh -c "elixir -S mix run examples/counter.exs"

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
    vbox(
      constraints: [length: 1, length: 1, fill: 1, length: 1, length: 1],
      children: [
        text("Harlock Counter", style: [bold: true]),
        text(String.duplicate("─", 30)),
        text("count: #{m.n}", style: [fg: :cyan, bold: true]),
        spacer(),
        text("[+/=] inc  [-] dec  [q/Esc] quit", style: [dim: true])
      ]
    )
  end
end

# If running via `mix run examples/counter.exs` (rather than loading via iex),
# kick off the app immediately.
case System.argv() do
  ["--run"] -> Harlock.run(Counter)
  _ -> :ok
end
