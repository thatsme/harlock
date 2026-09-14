# Verifies that mouse reporting is turned on when an app asks for it and off
# again on every way out: quitting, crashing, and handing the terminal to a
# program with Cmd.exec (and back). A terminal left reporting clicks after an
# app exits types escape sequences into the shell.
#
# Runs through priv/mouse_smoke.run.sh, which records the pty's output; each
# case writes a marker, then reads back what was written after it.

defmodule MouseSmoke do
  def fail(msg) do
    IO.puts(:stderr, "FAIL: " <> msg)
    System.halt(1)
  end

  def check(label, true), do: IO.puts("ok   " <> label)
  def check(label, other), do: fail("#{label} (got #{inspect(other)})")

  def eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end

defmodule MouseApp do
  use Harlock.App

  def init(_), do: %{}

  def update(:boom, _m), do: raise("deliberate crash")
  def update(:quit, _m), do: :quit
  def update({:run, argv}, m), do: {m, Harlock.Cmd.exec(hd(argv), tl(argv))}
  def update(_, m), do: m

  def view(_), do: text("mouse smoke")
end

alias MouseSmoke, as: S

dir = System.get_env("HARLOCK_SMOKE_DIR") || S.fail("run through scripts/smoke.sh")
log = Path.join(dir, "tty.log")
on = "\e[?1006h"
off = "\e[?1006l"

# Everything written to the terminal since `marker` was printed.
since = fn marker ->
  case log |> File.read!() |> String.split(marker, parts: 2) do
    [_, after_marker] -> after_marker
    _ -> ""
  end
end

runtime_name = :"Elixir.Harlock.App.Supervisor.Runtime"

run_case = fn name, opts, drive ->
  marker = "MOUSE-SMOKE-CASE-#{name}"
  IO.puts(marker)
  S.eventually(fn -> since.(marker) != "" or File.read!(log) =~ marker end)

  parent = self()
  spawn(fn -> send(parent, {:returned, Harlock.run(MouseApp, nil, opts)}) end)
  S.eventually(fn -> Process.whereis(runtime_name) != nil end)
  drive.(Process.whereis(runtime_name), fn -> since.(marker) end)

  receive do
    {:returned, _} -> :ok
  after
    5_000 -> S.fail("#{name}: app did not end")
  end

  Process.sleep(200)
  since.(marker)
end

# Positions of each occurrence of `pattern` in `bytes`, in order.
positions = fn bytes, pattern ->
  bytes |> :binary.matches(pattern) |> Enum.map(&elem(&1, 0))
end

# Careful with empty lists: List.last([]) is nil, and nil sorts after every
# number, so a missing sequence would compare as "later" than any present one.
last_on_then_off? = fn bytes ->
  case {positions.(bytes, on), positions.(bytes, off)} do
    {[_ | _] = ons, [_ | _] = offs} -> List.last(offs) > List.last(ons)
    _ -> false
  end
end

# 1. Quit.
out =
  run_case.("quit", [mouse: true], fn runtime, written ->
    S.eventually(fn -> written.() =~ on end)
    send(runtime, {:harlock_event, :quit})
  end)

S.check("quit: reporting turned on, then off", last_on_then_off?.(out))

# 2. A crash in update/2.
out =
  run_case.("crash", [mouse: true], fn runtime, written ->
    S.eventually(fn -> written.() =~ on end)
    send(runtime, {:harlock_event, :boom})
  end)

S.check("crash: reporting turned on, then off", last_on_then_off?.(out))

# 3. Handing the terminal to a program and back: off while it runs, on again
#    after, off at the end.
out =
  run_case.("exec", [mouse: true], fn runtime, written ->
    S.eventually(fn -> written.() =~ on end)
    send(runtime, {:harlock_event, {:run, ["sh", "-c", "echo PROGRAM-RUNNING; sleep 0.3"]}})
    S.eventually(fn -> length(positions.(written.(), on)) >= 2 end)
    send(runtime, {:harlock_event, :quit})
  end)

[program] = positions.(out, "PROGRAM-RUNNING")
ons = positions.(out, on)
offs = positions.(out, off)

S.check("exec: off before the program runs", Enum.any?(offs, &(&1 < program and &1 > hd(ons))))
S.check("exec: on again after it returns", Enum.any?(ons, &(&1 > program)))
S.check("exec: off at the end", last_on_then_off?.(out))

# 4. Without mouse: true reporting is never turned on (and leaving still turns
#    it off, which is harmless).
out =
  run_case.("off", [], fn runtime, _written ->
    Process.sleep(300)
    send(runtime, {:harlock_event, :quit})
  end)

S.check("without mouse: true it is never turned on", positions.(out, on) == [])

IO.puts("PASS")
System.halt(0)
