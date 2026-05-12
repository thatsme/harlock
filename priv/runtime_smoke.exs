# Boots the AppSupervisor with the Counter app, lets it render a frame,
# injects a synthetic {q} keypress directly into the runtime mailbox
# (bypassing the Reader so this works without a real keyboard), and
# verifies the app exits cleanly with the terminal restored.
#
# Run with: docker compose run --rm dev script -qc "mix run priv/runtime_smoke.exs" /dev/null

Code.require_file("examples/counter.exs")

parent = self()

# Run the app in a separate process so we can poke its supervisor from here.
_runner =
  spawn(fn ->
    result = Harlock.run(Counter)
    send(parent, {:done, result})
  end)

# Give the supervisor + runtime time to start and render the first frame.
Process.sleep(600)

runtime_name = :"Elixir.Harlock.App.Supervisor.Runtime"

case Process.whereis(runtime_name) do
  nil ->
    IO.puts(:stderr, "FAIL: runtime not registered as #{inspect(runtime_name)}")
    IO.inspect(Process.registered() |> Enum.filter(&(&1 |> Atom.to_string() |> String.contains?("Harlock"))),
      label: "Harlock-prefixed names"
    )
    System.halt(1)

  pid ->
    send(pid, {:harlock_event, {:key, {:char, ?q}, []}})
end

result =
  receive do
    {:done, r} -> r
  after
    4_000 -> :timeout
  end

IO.inspect(result, label: "runtime_smoke result")

case result do
  {:ok, :normal} -> System.halt(0)
  _ -> System.halt(1)
end
