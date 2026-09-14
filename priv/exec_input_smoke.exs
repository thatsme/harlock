# Verifies that keystrokes typed while a program holds the terminal reach the
# program and not the app — and that the app reads them again afterwards.
#
# Driven by priv/exec_input_smoke.drive.sh, which scripts/smoke.sh pipes into
# the pty. The two sides coordinate through files in $HARLOCK_SMOKE_DIR:
#
#   app_ready      (this script)  driver types "r": the app runs a program
#   program_ready  (the program)  driver types a line: the program reads it
#   app_back       (this script)  driver types "z": the app should get it
#   done           (this script)  driver exits

defmodule ExecInputSmoke do
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

defmodule InputApp do
  use Harlock.App

  def init(dir), do: %{dir: dir, keys: [], result: nil}

  def update({:key, {:char, ?r}, []} = key, m) do
    script = ~S|touch "$1/program_ready"; IFS= read -r line; printf '%s' "$line" > "$1/line"|

    {%{m | keys: m.keys ++ [key]},
     Harlock.Cmd.exec("sh", ["-c", script, "sh", m.dir]) |> Harlock.Cmd.map(&{:ran, &1})}
  end

  def update({:key, _, _} = key, m), do: %{m | keys: m.keys ++ [key]}
  def update({:ran, result}, m), do: %{m | result: result}
  def update(:quit, _m), do: :quit
  def update(_, m), do: m

  def view(m), do: text("keys: #{length(m.keys)} result: #{inspect(m.result)}")
end

alias ExecInputSmoke, as: S

dir =
  System.get_env("HARLOCK_SMOKE_DIR") ||
    S.fail("HARLOCK_SMOKE_DIR not set; run through scripts/smoke.sh")

touch = fn name -> File.write!(Path.join(dir, name), "") end

parent = self()
spawn(fn -> send(parent, {:done, Harlock.run(InputApp, dir)}) end)

runtime = :"Elixir.Harlock.App.Supervisor.Runtime"
S.check("app started", S.eventually(fn -> Process.whereis(runtime) != nil end))
model = fn -> :sys.get_state(runtime).model end

touch.("app_ready")

S.check("the program ran and exited 0", S.eventually(fn -> model.().result == {:ok, 0} end))

S.check(
  "the program received the typed line",
  File.read!(Path.join(dir, "line")) == "typed into the program"
)

S.check("none of it reached the app", model.().keys == [{:key, {:char, ?r}, []}])

touch.("app_back")

S.check(
  "a key typed after the program exits reaches the app",
  S.eventually(fn -> List.last(model.().keys) == {:key, {:char, ?z}, []} end)
)

send(runtime, {:harlock_event, :quit})

receive do
  {:done, {:ok, :normal}} -> :ok
after
  4_000 -> S.fail("app did not quit")
end

touch.("done")
IO.puts("PASS")
System.halt(0)
