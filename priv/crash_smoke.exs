# Verifies that the terminal is restored when an app dies, including while
# another program holds the terminal through Cmd.exec.
#
# Each case starts an app on a real pty, ends it one way or another, and checks
# what a user would be left with: what Harlock.run returned (and that its caller
# is otherwise as it was), the terminal back in cooked mode, this BEAM holding
# the foreground, and no program left running. Needs ps, stty and a pty — run through scripts/smoke.sh.

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

  def update(:quit, _m), do: :quit
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

# Start the app from a caller process that reports what Harlock.run returned
# and the state it was left in. `setup` runs in the caller first.
# Returns the runtime pid, the (unnamed) supervisor pid, and a monitor ref on
# the caller.
start_with = fn setup ->
  parent = self()

  caller =
    spawn(fn ->
      setup.(parent)
      result = Harlock.run(CrashApp)
      {:trap_exit, trapping} = Process.info(self(), :trap_exit)
      {:messages, left} = Process.info(self(), :messages)
      send(parent, {:run_returned, result, trapping, left})
    end)

  ref = Process.monitor(caller)
  S.eventually(fn -> Process.whereis(runtime_name) != nil end)
  runtime = Process.whereis(runtime_name)
  {:dictionary, dict} = Process.info(runtime, :dictionary)
  S.eventually(raw?)
  {runtime, hd(dict[:"$ancestors"]), ref}
end

start = fn -> start_with.(fn _parent -> :ok end) end

start_program = fn runtime ->
  send(runtime, {:harlock_event, {:run, "sleep", ["30"]}})
  S.eventually(fn -> not Termios.foreground?(probe) end)
  pgid = foreground_pgid.()

  if pgid ==
       :os.cmd(~c"ps -o pgid= -p #{beam}") |> to_string() |> String.trim() |> String.to_integer(),
     do: S.fail("program never took the foreground")

  pgid
end

# The caller sends its report and then exits normally, so a report is followed
# by that DOWN; consume it so the next case does not mistake it for its own.
ended = fn ref ->
  receive do
    {:run_returned, result, trapping, left} ->
      receive do: ({:DOWN, ^ref, :process, _, _} -> :ok)
      {:returned, result, trapping, left}

    {:DOWN, ^ref, :process, _, reason} ->
      {:caller_exited, reason}
  after
    5_000 -> :still_running
  end
end

# `expected` matches what the caller should see: {:returned, result, trapping,
# leftover messages} or {:caller_exited, reason}.
expect_restored = fn label, ref, pgid, expected ->
  S.check("#{label}", expected.(ended.(ref)))
  S.check("#{label}: terminal back in cooked mode", S.eventually(fn -> not raw?.() end))
  S.check("#{label}: BEAM holds the foreground", Termios.foreground?(probe))

  if pgid,
    do: S.check("#{label}: the program is gone", S.eventually(fn -> not group_alive?.(pgid) end))
end

crash_returns_error = fn
  {:returned, {:error, _}, false, []} -> true
  other -> other
end

# 1. update/2 raises, no program running.
{runtime, _sup, ref} = start.()
send(runtime, {:harlock_event, :boom})
expect_restored.("crash in update/2 returns an error", ref, nil, crash_returns_error)

# 2. update/2 raises while a program holds the terminal.
{runtime, _sup, ref} = start.()
pgid = start_program.(runtime)
send(runtime, {:harlock_event, :boom})
expect_restored.("crash during exec returns an error", ref, pgid, crash_returns_error)

# 3. The supervisor is killed outright while a program holds the terminal. Its
#    children get an exit signal from their parent and run terminate/2.
#    (:kill rather than :shutdown: a supervisor ignores exit signals from
#    anything but its parent unless they are untrappable.)
{runtime, sup, ref} = start.()
pgid = start_program.(runtime)
Process.exit(sup, :kill)

expect_restored.("supervisor killed during exec", ref, pgid, fn
  {:returned, {:error, :killed}, false, []} -> true
  other -> other
end)

# 4. A normal quit: {:ok, :normal}, and the caller left exactly as it was.
{runtime, _sup, ref} = start.()
send(runtime, {:harlock_event, :quit})

expect_restored.("quit", ref, nil, fn
  {:returned, {:ok, :normal}, false, []} -> true
  other -> other
end)

# 5. Another process linked to the caller dies abnormally while the app runs.
#    Without run/3 in between that would kill the caller; it still does, and the
#    app is stopped on the way out.
{_runtime, _sup, ref} =
  start_with.(fn parent ->
    doomed = spawn_link(fn -> receive do: (:die -> exit(:linked_crash)) end)
    send(parent, {:doomed, doomed})
  end)

doomed = receive do: ({:doomed, pid} -> pid)
send(doomed, :die)

expect_restored.("a linked process crashing ends the caller", ref, nil, fn
  {:caller_exited, :linked_crash} -> true
  other -> other
end)

# 6. A caller that was already trapping exits keeps trapping them.
{runtime, _sup, ref} = start_with.(fn _parent -> Process.flag(:trap_exit, true) end)
send(runtime, {:harlock_event, :boom})

expect_restored.("crash with a trapping caller", ref, nil, fn
  {:returned, {:error, _}, true, []} -> true
  other -> other
end)

IO.puts("PASS")
System.halt(0)
