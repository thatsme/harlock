# Verifies that log output stays off the screen while an app runs and is printed
# once the terminal is handed back: in a real pty, with standard output sent to
# a file by log_smoke.run.sh, since the console logger writes there and Harlock
# draws on /dev/tty.
#
#   1. Nothing logged during a session reaches standard output during it.
#   2. It all arrives after Harlock.run returns, in order.
#   3. A crash's report arrives the same way.
#   4. The console handler is itself again afterwards: its level restored, the
#      mirror handler gone, and a new log call written straight away.

require Logger

dir = System.fetch_env!("HARLOCK_SMOKE_DIR")
stdout = Path.join(dir, "stdout")

fail = fn message ->
  IO.puts(:stderr, "FAIL: " <> message)
  System.halt(1)
end

# The console handler writes asynchronously; wait for it before reading.
read_stdout = fn ->
  _ = :logger_std_h.filesync(:default)
  File.read!(stdout)
end

defmodule LogSmoke.App do
  use Harlock.App

  require Logger

  def init(parent) do
    Logger.warning("harlock-smoke-init")
    {parent, Cmd.from(fn -> Process.sleep(300) && :during end)}
  end

  def update(:during, parent) do
    Logger.warning("harlock-smoke-during")
    {parent, Cmd.from(fn -> Process.sleep(300) && :check end)}
  end

  # The session is still running: the test reads standard output now.
  def update(:check, parent) do
    send(parent, {:check, self()})

    receive do
      :checked -> :quit
    after
      5_000 -> :quit
    end
  end

  def update(_, parent), do: parent
  def view(_), do: text("log smoke")
end

defmodule LogSmoke.Crash do
  use Harlock.App

  def init(_), do: {nil, Cmd.from(fn -> Process.sleep(200) && :boom end)}
  def update(:boom, _), do: raise("harlock-smoke-boom")
  def update(_, m), do: m
  def view(_), do: text("crash smoke")
end

{:ok, %{level: level_before}} = :logger.get_handler_config(:default)
parent = self()

runner = spawn(fn -> send(parent, {:done, Harlock.run(LogSmoke.App, parent)}) end)

receive do
  {:check, app} ->
    during = read_stdout.()

    if String.contains?(during, "harlock-smoke") do
      fail.("log output reached standard output while the app ran:\n" <> during)
    end

    send(app, :checked)
after
  10_000 -> fail.("the app never reached its check")
end

receive do
  {:done, _result} -> :ok
after
  10_000 -> fail.("Harlock.run did not return (runner #{inspect(runner)})")
end

after_run = read_stdout.()

case {:binary.match(after_run, "harlock-smoke-init"),
      :binary.match(after_run, "harlock-smoke-during")} do
  {{init, _}, {during, _}} when init < during ->
    :ok

  other ->
    fail.("session logs missing or out of order after exit: #{inspect(other)}\n" <> after_run)
end

case Harlock.run(LogSmoke.Crash) do
  {:error, _} -> :ok
  other -> fail.("the crashing app returned #{inspect(other)}")
end

unless String.contains?(read_stdout.(), "harlock-smoke-boom") do
  fail.("the crash report was not printed after the terminal was restored")
end

case :logger.get_handler_config(:default) do
  {:ok, %{level: ^level_before}} -> :ok
  other -> fail.("console handler not restored: #{inspect(other)}")
end

if Enum.any?(
     :logger.get_handler_ids(),
     &String.starts_with?(Atom.to_string(&1), "harlock_log_buffer")
   ) do
  fail.("a mirror handler was left installed: #{inspect(:logger.get_handler_ids())}")
end

Logger.warning("harlock-smoke-after")

unless String.contains?(read_stdout.(), "harlock-smoke-after") do
  fail.("the console handler does not write after the session")
end

IO.puts(:stderr, "PASS")
System.halt(0)
