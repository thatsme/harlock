# Verifies the runtime's side of handing the terminal to another program: a
# real app, on a real pty, hands the terminal over and gets it back.
#
# Requests go straight to the runtime as {:harlock_exec, program, args, opts,
# reply};
# that message is what Cmd.exec dispatches to. Needs ps, stty and a pty — run
# through scripts/smoke.sh.

alias Harlock.Terminal.Termios

defmodule ExecRuntimeSmoke do
  def fail(msg) do
    IO.puts(:stderr, "FAIL: " <> msg)
    System.halt(1)
  end

  def ok(label), do: IO.puts("ok   " <> label)

  def check(label, true), do: ok(label)
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

defmodule ExecApp do
  use Harlock.App

  def init(_), do: %{results: [], ticks: 0}

  def subs(_m), do: [Harlock.Sub.interval(50, :tick)]

  def update(:tick, m), do: %{m | ticks: m.ticks + 1}
  def update({:exec_result, tag, result}, m), do: %{m | results: m.results ++ [{tag, result}]}

  # The public path: update/2 returns Cmd.exec, as an app would.
  def update({:run, tag, program, args, opts}, m),
    do: {m, Harlock.Cmd.exec(program, args, opts) |> Harlock.Cmd.map(&{:exec_result, tag, &1})}

  def update({:key, {:char, ?q}, []}, _m), do: :quit

  def update(:suspend, m),
    do: {m, Harlock.Cmd.suspend() |> Harlock.Cmd.map(&{:exec_result, :suspend, &1})}

  def update(_, m), do: m

  def view(m), do: text("ticks #{m.ticks} results #{length(m.results)}")
end

alias ExecRuntimeSmoke, as: S

tty_name = :os.cmd(~c"ps -o tty= -p #{System.pid()}") |> to_string() |> String.trim()
if tty_name in ["", "?", "??"], do: S.fail("no controlling tty; run through scripts/smoke.sh")
tty_path = "/dev/" <> tty_name
stty_flag = if match?({:unix, :linux}, :os.type()), do: "-F", else: "-f"
stty = fn args -> :os.cmd(~c"stty #{stty_flag} #{tty_path} #{args} 2>&1") |> to_string() end
raw? = fn -> stty.("-a") =~ "-icanon" end

stty.("rows 24 cols 80")

parent = self()
spawn(fn -> send(parent, {:done, Harlock.run(ExecApp)}) end)

runtime = :"Elixir.Harlock.App.Supervisor.Runtime"
S.check("app started", S.eventually(fn -> Process.whereis(runtime) != nil end))
model = fn -> runtime |> :sys.get_state() |> Map.fetch!(:model) end
rt_state = fn -> :sys.get_state(runtime) end
S.check("terminal is raw while the app runs", S.eventually(raw?))

# A tty handle of our own, only to ask who holds the foreground.
{:ok, probe} = Termios.open()

renders = :counters.new(1, [])

:telemetry.attach(
  "exec-smoke-renders",
  [:harlock, :frame, :render, :stop],
  fn _, _, _, _ -> :counters.add(renders, 1, 1) end,
  nil
)

exec = fn tag, [program | args], opts ->
  send(runtime, {:harlock_exec, program, args, opts, &{:exec_result, tag, &1}})
end

result_for = fn tag ->
  S.eventually(fn -> List.keymember?(model.().results, tag, 0) end, 200)
  model.().results |> List.keyfind(tag, 0) |> elem(1)
end

# 0. Through the public API: update/2 returns Cmd.exec. :cd is honoured, :env
#    adds to the environment rather than replacing it, and a nil value unsets.
#    Inheritance is checked with a variable of our own: sh invents a PATH when
#    none is inherited, so PATH cannot tell a merge from a replacement.
System.put_env("HARLOCK_SMOKE_UNSET_ME", "1")
System.put_env("HARLOCK_SMOKE_INHERITED", "1")
cd = System.tmp_dir!()
expected_dir = :os.cmd(~c"cd #{cd} && pwd -P") |> to_string() |> String.trim()

send(
  runtime,
  {:harlock_event,
   {:run, :public, "sh",
    [
      "-c",
      ~S|test "$HARLOCK_SMOKE_SET" = yes && test -z "${HARLOCK_SMOKE_UNSET_ME+x}" && test "$HARLOCK_SMOKE_INHERITED" = 1 && test "$(pwd -P)" = "$HARLOCK_SMOKE_DIR"|
    ],
    [
      cd: cd,
      env: [
        {"HARLOCK_SMOKE_SET", "yes"},
        {"HARLOCK_SMOKE_UNSET_ME", nil},
        {"HARLOCK_SMOKE_DIR", expected_dir}
      ]
    ]}}
)

S.check(
  "Cmd.exec from update/2, with :cd honoured and :env merged",
  result_for.(:public) == {:ok, 0}
)

# 1. Result delivered through update/2, with the exit code.
exec.(:code, ["sh", "-c", "exit 4"], [])
S.check("exit code arrives as {:ok, 4}", result_for.(:code) == {:ok, 4})

# 2. The program starts from the settings the shell left, not raw mode.
exec.(:cooked, ["sh", "-c", "stty -a | grep -q -- -icanon && exit 9 || exit 0"], [])
S.check("the program sees a cooked terminal", result_for.(:cooked) == {:ok, 0})

S.check("raw mode is back afterwards", S.eventually(raw?))
S.check("the BEAM holds the foreground again", Termios.foreground?(probe))

# 3. While a program runs: updates continue, nothing is drawn, a second exec is
#    refused, and a resize is picked up on return even though SIGWINCH went to
#    the program's group rather than this BEAM.
exec.(:long, ["sleep", "1"], [])

S.check(
  "the program takes the foreground",
  S.eventually(fn -> not Termios.foreground?(probe) end)
)

ticks_before = model.().ticks
renders_before = :counters.get(renders, 1)
exec.(:second, ["sh", "-c", "exit 0"], [])
stty.("rows 30 cols 100")
Process.sleep(500)

S.check("updates keep running during the program", model.().ticks > ticks_before)
S.check("nothing is drawn during the program", :counters.get(renders, 1) == renders_before)
S.check("the Reader is paused", :sys.get_state(:"Elixir.Harlock.App.Supervisor.Reader").paused)
S.check("a second exec is refused", result_for.(:second) == {:error, :busy})

S.check("the long program finishes", result_for.(:long) == {:ok, 0})
S.check("rendering resumes", S.eventually(fn -> :counters.get(renders, 1) > renders_before end))

S.check(
  "the size changed during the program is picked up",
  {rt_state.().rows, rt_state.().cols} == {30, 100}
)

S.check(
  "the Reader is reading again",
  not :sys.get_state(:"Elixir.Harlock.App.Supervisor.Reader").paused
)

# 4. A program that cannot start leaves the app as it was.
exec.(:missing, ["harlock-no-such-program"], [])

S.check(
  "a missing program is {:error, {:exec, :enoent}}",
  result_for.(:missing) == {:error, {:exec, :enoent}}
)

S.check("raw mode after a failed start", S.eventually(raw?))
S.check("foreground after a failed start", Termios.foreground?(probe))

# 5. Suspending without a job-control shell is refused, and the terminal is not
#    touched. Under script(1) this BEAM's process group is orphaned, so a
#    SIGTSTP would be discarded and nothing would ever resume it.
send(runtime, {:harlock_event, :suspend})

S.check(
  "suspend without job control is {:error, :no_job_control}",
  result_for.(:suspend) == {:error, :no_job_control}
)

S.check("  ...leaving raw mode alone", raw?.())
S.check("  ...and the foreground", Termios.foreground?(probe))

S.check(
  "  ...and the alternate screen",
  :sys.get_state(:"Elixir.Harlock.App.Supervisor.Writer").entered
)

S.check("  ...and input", not :sys.get_state(:"Elixir.Harlock.App.Supervisor.Reader").paused)

# 6. The app still quits cleanly and restores the terminal.
send(runtime, {:harlock_event, {:key, {:char, ?q}, []}})

receive do
  {:done, {:ok, :normal}} -> S.ok("app quits normally afterwards")
  {:done, other} -> S.fail("app exited with #{inspect(other)}")
after
  4_000 -> S.fail("app did not quit")
end

S.check("terminal restored to cooked on exit", S.eventually(fn -> not raw?.() end))

IO.puts("PASS")
System.halt(0)
