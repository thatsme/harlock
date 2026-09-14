# Verifies the native layer behind handing the terminal to another program:
# Termios.exec_start/3 and friends, and the harlock_exec helper.
#
# Needs a real pty (run through scripts/smoke.sh): the program has to become
# the terminal's foreground process group, which only happens on a terminal
# this BEAM controls. Every case reclaims the foreground afterwards and checks
# it came back.

alias Harlock.Terminal.Termios

defmodule ExecSmoke do
  alias Harlock.Terminal.Termios

  def fail(msg) do
    IO.puts(:stderr, "FAIL: " <> msg)
    System.halt(1)
  end

  # Start, wait for the helper's report, reclaim the terminal.
  def run(tty, argv, opts \\ [], during \\ fn _pgid -> :ok end) do
    {exec, pgid} =
      case Termios.exec_start(tty, argv, opts) do
        {:ok, exec, pgid} -> {exec, pgid}
        other -> fail("exec_start #{inspect(argv)} returned #{inspect(other)}")
      end

    during.({exec, pgid})
    result = await(exec)

    unless Termios.reclaim_foreground(tty) == :ok and Termios.foreground?(tty) == true,
      do: fail("foreground not reclaimed after #{inspect(argv)}")

    result
  end

  defp await(exec) do
    :ok = Termios.exec_arm(exec)

    receive do
      {:exec_ready, ^exec} ->
        case Termios.exec_read(exec) do
          :wouldblock -> await(exec)
          result -> result
        end
    after
      10_000 -> fail("no result within 10s")
    end
  end

  def expect(label, actual, expected) do
    if actual == expected do
      IO.puts("ok   #{label}")
    else
      fail("#{label}: expected #{inspect(expected)}, got #{inspect(actual)}")
    end
  end

  def group_alive?(pgid) do
    :os.cmd(~c"ps -A -o pgid=")
    |> to_string()
    |> String.split()
    |> Enum.member?(Integer.to_string(pgid))
  end
end

tty =
  case Termios.open() do
    {:ok, tty} ->
      tty

    other ->
      ExecSmoke.fail("no controlling tty (#{inspect(other)}); run through scripts/smoke.sh")
  end

unless Termios.foreground?(tty), do: ExecSmoke.fail("BEAM does not start in the foreground")

dir = Path.join(System.tmp_dir!(), "harlock_exec_smoke_#{System.unique_integer([:positive])}")
File.mkdir_p!(dir)
out = Path.join(dir, "out")
env_with_out = System.get_env() |> Map.put("OUT", out)
read_out = fn -> out |> File.read!() |> String.trim() end

ExecSmoke.expect("exit code", ExecSmoke.run(tty, ["sh", "-c", "exit 3"]), {:exited, 3})

ExecSmoke.expect(
  "program is the foreground group, owns /dev/tty, and has a blocking stdin",
  ExecSmoke.run(tty, [
    "sh",
    "-c",
    ~S"""
    exec 4</dev/tty || exit 10
    [ "$(ps -o tpgid= -p $$ | tr -d ' ')" = "$(ps -o pgid= -p $$ | tr -d ' ')" ] || exit 11
    test -t 0 || exit 12
    perl -MFcntl -e 'exit((fcntl(STDIN, F_GETFL, 0) & O_NONBLOCK) ? 13 : 0)'
    """
  ]),
  {:exited, 0}
)

ExecSmoke.expect(
  "a missing program is an exec failure",
  ExecSmoke.run(tty, ["harlock-no-such-program"]),
  {:failed, :exec, :enoent}
)

ExecSmoke.expect(
  "a missing directory is a chdir failure",
  ExecSmoke.run(tty, ["sh", "-c", "true"], cd: Path.join(dir, "missing")),
  {:failed, :chdir, :enoent}
)

ExecSmoke.expect(
  ":cd and :env reach the program",
  ExecSmoke.run(tty, ["sh", "-c", ~S(pwd -P > "$OUT")], cd: dir, env: env_with_out),
  {:exited, 0}
)

ExecSmoke.expect(
  "  ...the directory it saw",
  read_out.(),
  :os.cmd(~c"cd #{dir} && pwd -P") |> to_string() |> String.trim()
)

ExecSmoke.expect(
  "death by signal is reported as such",
  ExecSmoke.run(tty, ["sh", "-c", "kill -TERM $$"]),
  {:signaled, 15}
)

ExecSmoke.expect(
  "SIGINT to the foreground group ends the program, not the BEAM",
  ExecSmoke.run(tty, ["sleep", "5"], [], fn {_exec, pgid} ->
    Process.sleep(200)
    :os.cmd(~c"kill -INT -#{pgid}")
  end),
  {:signaled, 2}
)

ExecSmoke.expect(
  "a stopped program is resumed rather than left stopped",
  ExecSmoke.run(tty, ["sh", "-c", ~S(kill -STOP $$; echo resumed > "$OUT")], env: env_with_out),
  {:exited, 0}
)

ExecSmoke.expect("  ...and ran to completion", read_out.(), "resumed")

ExecSmoke.expect(
  "exec_kill ends the whole group",
  ExecSmoke.run(tty, ["sleep", "30"], [], fn {exec, pgid} ->
    Process.sleep(200)
    :ok = Termios.exec_kill(exec)
    Process.sleep(200)

    if ExecSmoke.group_alive?(pgid),
      do: ExecSmoke.fail("process group #{pgid} survived exec_kill")
  end),
  :killed
)

fd_dir = if match?({:unix, :linux}, :os.type()), do: "/proc/self/fd", else: "/dev/fd"

ExecSmoke.expect(
  "no BEAM descriptors leak into the program",
  # Shell artifacts would pollute this: macOS ls opens two descriptors of its
  # own to walk a directory, and a redirect on a compound command makes sh save
  # stdout on fd 10. So: redirect with exec, and list with a glob.
  ExecSmoke.run(
    tty,
    ["sh", "-c", ~s(exec > "$OUT"; for f in #{fd_dir}/*; do echo "${f##*/}"; done)],
    env: env_with_out
  ),
  {:exited, 0}
)

fds = read_out.() |> String.split() |> Enum.map(&String.to_integer/1)

# 0 and 2 are the tty, 1 is $OUT, and the glob opens one to read the directory.
unless Enum.all?(fds, &(&1 <= 3)),
  do: ExecSmoke.fail("program inherited descriptors #{inspect(fds -- [0, 1, 2, 3])}")

IO.puts("ok   (descriptors seen: #{inspect(fds)})")

File.rm_rf!(dir)
IO.puts("PASS")
System.halt(0)
