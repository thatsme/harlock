# Run with:
#   ./scripts/run.sh counter
#
# or directly:
#   mix run examples/counter.exs --run
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes.
#
# The smallest app: a number, keys to change it, and two buttons that do the
# same by click, or by Tab and Enter.

defmodule Counter do
  use Harlock.App

  def init(_), do: %{n: 0}

  def update({:key, {:char, ?+}, []}, m), do: inc(m)
  def update({:key, {:char, ?=}, []}, m), do: inc(m)
  def update({:key, {:char, ?-}, []}, m), do: dec(m)
  def update({:harlock_submit, :inc}, m), do: inc(m)
  def update({:harlock_submit, :dec}, m), do: dec(m)
  def update({:key, {:char, ?q}, []}, _), do: :quit
  def update({:key, :escape, []}, _), do: :quit
  def update(_event, m), do: m

  defp inc(m), do: %{m | n: m.n + 1}
  defp dec(m), do: %{m | n: max(0, m.n - 1)}

  def view(m) do
    box(
      title: "Harlock Counter",
      title_align: :center,
      border: :rounded,
      border_style: [fg: :cyan],
      padding: {1, 2},
      child:
        vbox(
          constraints: [fill: 1, length: 1, length: 1, length: 1],
          children: [
            text(["count: ", {"#{m.n}", fg: :cyan, bold: true}]),
            hbox(
              constraints: [length: 6, length: 6, fill: 1],
              children: [
                button("-", focusable: :dec),
                button("+", focusable: :inc),
                spacer()
              ]
            ),
            spacer(),
            text("[+/=] inc  [-] dec  [Tab] buttons  [q/Esc] quit", style: [dim: true])
          ]
        )
    )
  end

  @doc false
  # The options `--run` starts the app with. The tests start it with these too,
  # so a test cannot pass on an option the real app never sets.
  def run_opts, do: [mouse: true]
end

# `--run` starts the app; without it the file only defines the module, which is
# how the tests load it.
case System.argv() do
  ["--run"] -> Harlock.run(Counter, nil, Counter.run_opts())
  _ -> :ok
end
