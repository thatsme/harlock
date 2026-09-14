# Verifies that resizing the real terminal reflows a running app: starts
# Counter on a pty, changes the pty's size, and checks the runtime picked up
# the new dimensions.
#
# Nothing is injected. The kernel sends SIGWINCH when the window size changes,
# and the only route from there to the runtime is Keeper's signal handler —
# the step that was broken while every in-process resize test passed.
#
# Needs a pty (run through scripts/smoke.sh) and `ps` + `stty` on PATH.

Code.require_file("examples/counter.exs")

fail = fn msg ->
  IO.puts(:stderr, "FAIL: " <> msg)
  System.halt(1)
end

# The shells :os.cmd spawns have no controlling terminal, so they cannot use
# /dev/tty. They can open the pty by path, which is all stty needs.
tty =
  case :os.cmd(~c"ps -o tty= -p #{System.pid()}") |> to_string() |> String.trim() do
    "" -> fail.("could not determine this BEAM's tty")
    "?" <> _ -> fail.("no controlling tty; run through scripts/smoke.sh")
    name -> "/dev/" <> name
  end

stty_device_flag =
  case :os.type() do
    {:unix, :linux} -> "-F"
    {:unix, _bsd_or_darwin} -> "-f"
  end

set_size = fn rows, cols ->
  out = :os.cmd(~c"stty #{stty_device_flag} #{tty} rows #{rows} cols #{cols} 2>&1; echo $?")
  unless out |> to_string() |> String.trim() |> String.ends_with?("0"),
    do: fail.("stty could not resize #{tty}: #{out}")
end

set_size.(24, 80)

parent = self()
spawn(fn -> send(parent, {:done, Harlock.run(Counter)}) end)

runtime_name = :"Elixir.Harlock.App.Supervisor.Runtime"

size_of = fn ->
  case Process.whereis(runtime_name) do
    nil -> nil
    pid -> pid |> :sys.get_state() |> Map.take([:rows, :cols])
  end
end

wait_for = fn expected ->
  Enum.reduce_while(1..40, nil, fn _, _ ->
    case size_of.() do
      ^expected ->
        {:halt, expected}

      other ->
        Process.sleep(50)
        {:cont, other}
    end
  end)
end

case wait_for.(%{rows: 24, cols: 80}) do
  %{rows: 24, cols: 80} -> :ok
  other -> fail.("runtime did not start at 24x80, saw #{inspect(other)}")
end

set_size.(30, 100)

case wait_for.(%{rows: 30, cols: 100}) do
  %{rows: 30, cols: 100} -> :ok
  other -> fail.("runtime did not reflow to 30x100 after resize, still #{inspect(other)}")
end

# A second resize, smaller, so the first one passing is not a fluke of timing.
set_size.(20, 60)

case wait_for.(%{rows: 20, cols: 60}) do
  %{rows: 20, cols: 60} -> :ok
  other -> fail.("runtime did not reflow to 20x60 after resize, still #{inspect(other)}")
end

send(Process.whereis(runtime_name), {:harlock_event, {:key, {:char, ?q}, []}})

receive do
  {:done, {:ok, :normal}} ->
    IO.puts("PASS")
    System.halt(0)

  {:done, other} ->
    fail.("app exited with #{inspect(other)}")
after
  4_000 -> fail.("app did not exit on q")
end
