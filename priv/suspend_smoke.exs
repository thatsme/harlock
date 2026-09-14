# Verifies Cmd.suspend under a real job-control shell: the app hands the
# terminal back and stops, the shell sees a stopped job with a cooked terminal,
# and after `fg` the app has the terminal again and receives {:ok, :resumed}.
#
# Run through scripts/smoke.sh, which uses priv/suspend_smoke.run.sh to start
# this as a bash job; the two coordinate through $HARLOCK_SMOKE_DIR.

alias Harlock.Terminal.Termios

defmodule SuspendSmoke do
  def fail(msg) do
    IO.puts(:stderr, "FAIL: " <> msg)
    System.halt(1)
  end

  def check(label, true), do: IO.puts("ok   " <> label)
  def check(label, other), do: fail("#{label} (got #{inspect(other)})")

  def eventually(fun, tries \\ 200) do
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

defmodule SuspendApp do
  use Harlock.App

  def init(_), do: %{result: nil}

  def update({:key, {:char, ?z}, [:ctrl]}, m),
    do: {m, Harlock.Cmd.suspend() |> Harlock.Cmd.map(&{:suspended, &1})}

  def update({:suspended, result}, m), do: %{m | result: result}
  def update(:quit, _m), do: :quit
  def update(_, m), do: m

  def view(m), do: text("suspend smoke: #{inspect(m.result)}")
end

alias SuspendSmoke, as: S

dir =
  System.get_env("HARLOCK_SMOKE_DIR") ||
    S.fail("HARLOCK_SMOKE_DIR not set; run through scripts/smoke.sh")

tty_name = :os.cmd(~c"ps -o tty= -p #{System.pid()}") |> to_string() |> String.trim()
stty_flag = if match?({:unix, :linux}, :os.type()), do: "-F", else: "-f"
raw? = fn -> :os.cmd(~c"stty #{stty_flag} /dev/#{tty_name} -a") |> to_string() =~ "-icanon" end

parent = self()
spawn(fn -> send(parent, {:done, Harlock.run(SuspendApp)}) end)

runtime = :"Elixir.Harlock.App.Supervisor.Runtime"
S.check("app started", S.eventually(fn -> Process.whereis(runtime) != nil end))
S.check("terminal is raw while the app runs", S.eventually(raw?))
{:ok, probe} = Termios.open()

send(runtime, {:harlock_event, {:key, {:char, ?z}, [:ctrl]}})

S.check(
  "the app receives {:ok, :resumed} after fg",
  S.eventually(fn -> :sys.get_state(runtime).model.result == {:ok, :resumed} end)
)

S.check("the shell saw the job stop", File.exists?(Path.join(dir, "stopped")))

stty_while_stopped = File.read!(Path.join(dir, "stty_while_stopped"))

# Interactive bash restores its own terminal modes when a job stops, so this
# shows what a user gets rather than isolating Harlock's restore. That restore
# is the code path Cmd.exec uses, checked by exec_runtime_smoke's "the program
# sees a cooked terminal".
S.check(
  "the shell has a cooked terminal while the app is stopped",
  stty_while_stopped =~ "icanon" and not (stty_while_stopped =~ "-icanon")
)

S.check("raw mode is back", S.eventually(raw?))
S.check("the BEAM holds the foreground", Termios.foreground?(probe))
S.check("the Writer re-entered", :sys.get_state(:"Elixir.Harlock.App.Supervisor.Writer").entered)

S.check(
  "the Reader is reading",
  not :sys.get_state(:"Elixir.Harlock.App.Supervisor.Reader").paused
)

send(runtime, {:harlock_event, :quit})

receive do
  {:done, {:ok, :normal}} -> S.check("app quits normally afterwards", true)
after
  4_000 -> S.fail("app did not quit")
end

IO.puts("PASS")
System.halt(0)
