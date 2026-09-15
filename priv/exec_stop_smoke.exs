# Verifies Ctrl-Z inside a program started by Cmd.exec, under a real job-control
# shell: the program stops, the app stops with it so the shell shows the job
# suspended, and `fg` resumes both — the program runs to completion and the app
# gets its terminal back.
#
# Run through scripts/smoke.sh, which uses priv/exec_stop_smoke.run.sh to start
# this as a bash job; the two coordinate through $HARLOCK_SMOKE_DIR. The
# program stops itself with `kill -TSTP $$`, which is what vim does on Ctrl-Z.

alias Harlock.Terminal.Termios

defmodule ExecStopSmoke do
  def fail(msg) do
    IO.puts(:stderr, "FAIL: " <> msg)
    System.halt(1)
  end

  def check(label, true), do: IO.puts("ok   " <> label)
  def check(label, other), do: fail("#{label} (got #{inspect(other)})")

  def eventually(fun, tries \\ 300) do
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

defmodule ExecStopApp do
  use Harlock.App

  def init(_), do: %{result: nil}

  def update({:run, dir}, m) do
    script = ~S|echo $$ > "$1/program_pid"; kill -TSTP $$; echo resumed > "$1/program_resumed"|
    {m, Harlock.Cmd.exec("sh", ["-c", script, "sh", dir]) |> Harlock.Cmd.map(&{:ran, &1})}
  end

  def update({:ran, result}, m), do: %{m | result: result}
  def update(:quit, _m), do: :quit
  def update(_, m), do: m

  def view(m), do: text("exec stop smoke: #{inspect(m.result)}")
end

alias ExecStopSmoke, as: S

dir =
  System.get_env("HARLOCK_SMOKE_DIR") ||
    S.fail("HARLOCK_SMOKE_DIR not set; run through scripts/smoke.sh")

tty_name = :os.cmd(~c"ps -o tty= -p #{System.pid()}") |> to_string() |> String.trim()
stty_flag = if match?({:unix, :linux}, :os.type()), do: "-F", else: "-f"
raw? = fn -> :os.cmd(~c"stty #{stty_flag} /dev/#{tty_name} -a") |> to_string() =~ "-icanon" end

parent = self()
spawn(fn -> send(parent, {:done, Harlock.run(ExecStopApp)}) end)

runtime = :"Elixir.Harlock.App.Supervisor.Runtime"
S.check("app started", S.eventually(fn -> Process.whereis(runtime) != nil end))
{:ok, probe} = Termios.open()

send(runtime, {:harlock_event, {:run, dir}})

S.check(
  "the program runs to completion after fg",
  S.eventually(fn -> :sys.get_state(runtime).model.result == {:ok, 0} end)
)

S.check("the shell saw the job stop", File.exists?(Path.join(dir, "job_stopped")))

S.check(
  "  ...with the program stopped while it did",
  dir |> Path.join("program_state") |> File.read!() |> String.trim() |> String.starts_with?("T")
)

S.check(
  "the program carried on from where it stopped",
  File.exists?(Path.join(dir, "program_resumed"))
)

S.check("raw mode is back", S.eventually(raw?))
S.check("the BEAM holds the foreground", Termios.foreground?(probe))

send(runtime, {:harlock_event, :quit})

receive do
  {:done, {:ok, :normal}} -> S.check("app quits normally afterwards", true)
after
  4_000 -> S.fail("app did not quit")
end

IO.puts("PASS")
System.halt(0)
