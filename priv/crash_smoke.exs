# Verifies that the terminal is restored when an app dies, including while
# another program holds the terminal through Cmd.exec.
#
# Each case starts an app on a real pty, kills it one way or another, and
# checks what a user would be left with: the caller of Harlock.run told the app
# ended, the terminal back in cooked mode, this BEAM holding the foreground, and
# no program left running.
#
# "Told" accepts either Harlock.run returning or its calling process exiting:
# run links the supervisor it starts, so a tree shut down by a crash takes the
# caller with it rather than returning {:error, reason}. Needs ps, stty and a pty — run through scripts/smoke.sh.

alias Harlock.Terminal.Termios

defmodule CrashSmoke do
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

defmodule CrashApp do
  use Harlock.App

  def init(_), do: %{}

  def update(:boom, _m), do: raise("deliberate crash in update/2")

  def update({:run, program, args}, m),
    do: {m, Harlock.Cmd.exec(program, args) |> Harlock.Cmd.map(&{:ran, &1})}

  def update(_, m), do: m

  def view(_), do: text("crash smoke")
end

alias CrashSmoke, as: S

beam = System.pid()
tty_name = :os.cmd(~c"ps -o tty= -p #{beam}") |> to_string() |> String.trim()
if tty_name in ["", "?", "??"], do: S.fail("no controlling tty; run through scripts/smoke.sh")
stty_flag = if match?({:unix, :linux}, :os.type()), do: "-F", else: "-f"
raw? = fn -> :os.cmd(~c"stty #{stty_flag} /dev/#{tty_name} -a") |> to_string() =~ "-icanon" end
{:ok, probe} = Termios.open()

foreground_pgid = fn ->
  :os.cmd(~c"ps -o tpgid= -p #{beam}") |> to_string() |> String.trim() |> String.to_integer()
end

group_alive? = fn pgid ->
  :os.cmd(~c"ps -A -o pgid=") |> to_string() |> String.split() |> Enum.member?("#{pgid}")
end

runtime_name = :"Elixir.Harlock.App.Supervisor.Runtime"

# Start the app; return the runtime pid and the (unnamed) supervisor pid.
start = fn ->
  parent = self()
  caller = spawn(fn -> send(parent, {:run_returned, Harlock.run(CrashApp)}) end)
  Process.monitor(caller)
  S.eventually(fn -> Process.whereis(runtime_name) != nil end)
  runtime = Process.whereis(runtime_name)
  {:dictionary, dict} = Process.info(runtime, :dictionary)
  S.eventually(raw?)
  {runtime, hd(dict[:"$ancestors"])}
end

start_program = fn runtime ->
  send(runtime, {:harlock_event, {:run, "sleep", ["30"]}})
  S.eventually(fn -> not Termios.foreground?(probe) end)
  pgid = foreground_pgid.()

  if pgid ==
       :os.cmd(~c"ps -o pgid= -p #{beam}") |> to_string() |> String.trim() |> String.to_integer(),
     do: S.fail("program never took the foreground")

  pgid
end

expect_restored = fn label, pgid ->
  ended =
    receive do
      {:run_returned, result} -> {:returned, result}
      {:DOWN, _, :process, _, reason} -> {:caller_exited, reason}
    after
      5_000 -> :still_running
    end

  S.check("#{label}: the caller learns the app ended", ended != :still_running)
  S.check("#{label}: terminal back in cooked mode", S.eventually(fn -> not raw?.() end))
  S.check("#{label}: BEAM holds the foreground", Termios.foreground?(probe))

  if pgid,
    do: S.check("#{label}: the program is gone", S.eventually(fn -> not group_alive?.(pgid) end))
end

# 1. update/2 raises, no program running.
{runtime, _sup} = start.()
send(runtime, {:harlock_event, :boom})
expect_restored.("crash in update/2", nil)

# 2. update/2 raises while a program holds the terminal.
{runtime, _sup} = start.()
pgid = start_program.(runtime)
send(runtime, {:harlock_event, :boom})
expect_restored.("crash during exec", pgid)

# 3. The supervisor is killed outright while a program holds the terminal. Its
#    children get an exit signal from their parent and run terminate/2.
#    (:kill rather than :shutdown: a supervisor ignores exit signals from
#    anything but its parent unless they are untrappable.)
{runtime, sup} = start.()
pgid = start_program.(runtime)
Process.exit(sup, :kill)
expect_restored.("supervisor killed during exec", pgid)

IO.puts("PASS")
System.halt(0)
