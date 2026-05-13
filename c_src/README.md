# Harlock termios NIF

`termios.c` is the only piece of C in Harlock. It exists because the
BEAM cannot interact with the controlling terminal through `:os.cmd`,
`Port.open({:spawn, ...})`, or — surprisingly — spawn-based
`:file.read("/dev/tty")`. This README is the design rationale; future
maintainers debugging tty-leak issues or porting to a new platform
should read it first.

## Why a NIF at all

Three separate problems with `:os.cmd` and Port-based approaches:

1. **Controlling-tty loss.** `:os.cmd` and `Port.open({:spawn_executable,
   ...})` route through ERTS's `erl_child_setup`, which `setsid()`s
   child processes so killing them doesn't take down the BEAM. But
   `setsid()` detaches the child from the controlling terminal, so
   opening `/dev/tty` in the subshell returns ENXIO ("Device not
   configured"). Every `stty ... </dev/tty` call from inside BEAM
   silently fails.
2. **Spawn-based reads don't deliver bytes.** Verified empirically on
   macOS / OTP 28: `:file.open("/dev/tty", [:read, :raw, :binary])` from
   a spawned Erlang process opens successfully but `:file.read` never
   returns, even when the terminal is in raw mode and no other reader
   is active. Reads from the script's main process work. Cause
   undetermined — possibly something in ERTS's async-thread plumbing
   that's sensitive to which Erlang process initiated the call.
   Workaround would be "do all tty reads in the main script process,"
   which is incompatible with running under a supervisor.
3. **`Port.open({:fd, 0, 1}, ...)` on stdin** works only without
   `-noinput` and only by stealing fd 0 from BEAM's built-in
   `prim_tty:tty` driver. Brittle, racy against `user_drv`, and breaks
   if stdin is redirected.

A NIF doing `tcgetattr` / `tcsetattr` / `ioctl(TIOCGWINSZ)` / `read(2)`
directly bypasses all of these. The fd is opened from inside the BEAM
process, so it retains the controlling terminal; the syscalls run in
the calling thread, so they reach the kernel reliably regardless of
which Erlang process invoked them.

## Public API

| NIF                          | Purpose                                          |
| ---------------------------- | ------------------------------------------------ |
| `open/0`                     | open `/dev/tty` (O_RDWR \| O_NOCTTY \| O_NONBLOCK), returns resource |
| `close/1`                    | `SELECT_STOP` + close (via stop callback)        |
| `get/1` / `set/2`            | `tcgetattr` / `tcsetattr` — termios snapshot+restore |
| `set_raw/1`                  | `cfmakeraw` + VMIN=1, VTIME=0                    |
| `winsize/1`                  | `ioctl(TIOCGWINSZ)`                              |
| `arm_select/1`               | `enif_select_read` — get `{:tty_ready, ref}` on data |
| `read_nonblock/2`            | `read(2)` with EAGAIN → `:wouldblock`, 0 → `:eof` |

All NIFs run on dirty I/O schedulers except `arm_select`, which must
run on a normal scheduler so `enif_select_read` correctly identifies
the caller as the notification target.

## Resource lifecycle

```
Termios.open()
  → fd = open("/dev/tty", O_RDWR|O_NOCTTY|O_NONBLOCK)
  → resource holds {fd, owner_pid}
  → owner_pid set to enif_self() at open time

Termios.arm_select(ref)
  → enif_select_read(fd, resource, msg)
  → BEAM holds a ref to the resource; resource stays alive until select
    is stopped

(data available)
  → BEAM delivers msg = {:tty_ready, ref} to owner_pid

Termios.read_nonblock(ref, n)
  → read(2) into a binary
  → owner check: only the process that called open/0 may read

Termios.close(ref)
  → enif_select(SELECT_STOP)
  → resource.fd = -1 immediately (no more reads)
  → BEAM eventually invokes the stop callback on a scheduler thread
  → stop callback calls close(2) on the original fd
  → after stop completes, resource refcount drops, destructor runs
```

The destructor is idempotent: if `close/1` was called explicitly,
`resource.fd` is already `-1` and the destructor is a no-op. If the
resource is GC'd without an explicit close (e.g., process crashed),
the destructor itself calls `SELECT_STOP`, and BEAM defers the actual
free until the stop callback completes.

**Never `close(fd)` directly outside the stop callback.** Doing so
while the fd is still registered with `enif_select` is a use-after-free
in the BEAM IO poller and produces crashes that look entirely
unrelated.

## Why `enif_select_read` and not blocking `read(2)` in a dirty NIF

A blocking `read(2)` in a dirty I/O NIF technically works but it:

- Pins a dirty I/O scheduler thread for the lifetime of the read.
  Multiple apps would exhaust the pool.
- Can't be interrupted cleanly for shutdown. `tcsetattr` from another
  thread doesn't unblock `read` on all platforms.
- Ties shutdown sequencing to OS thread scheduling, which is
  platform-specific and unreliable.

`enif_select_read` registers the fd with the BEAM poller (kqueue on
macOS, epoll on Linux). The thread doing the wait is shared across all
fds the BEAM knows about. When data arrives, BEAM sends a message to
the registered process; the Erlang code does a non-blocking `read(2)`
and re-arms. This is the same path BEAM's built-in drivers use.

## Owner-pid check

Each NIF that touches the fd verifies the calling process is the one
that opened it:

```c
ErlNifPid caller;
enif_self(env, &caller);
if (enif_compare_pids(&caller, &tty->owner) != 0) {
    return {:error, :not_owner};
}
```

This isn't security — it's a footgun guard. Two Erlang processes
trying to drive one tty fd would race for messages and produce
silently-corrupted input streams. The check makes the misuse
fail-fast.

## Caveats and known limitations

- **Single-reader constraint.** Only one Harlock app per BEAM can
  usefully own `/dev/tty`. `Harlock.run/3` doesn't enforce this yet —
  v0.3 should detect and refuse.
- **Non-tty environments.** `Termios.open/0` returns
  `{:error, :no_tty}` when `/dev/tty` is unavailable (CI, piped stdin).
  Keeper surfaces this to stderr and halts the supervisor cleanly.
- **EOF handling.** A `read(2)` returning 0 means the terminal was
  closed (ssh disconnect, tmux kill-window). The Reader surfaces this
  as `{:harlock_event, {:harlock_tty_lost, :eof}}` to the runtime and
  terminates; the supervisor's `rest_for_one` then takes down the
  rest of the tree and Keeper's `terminate/2` restores termios before
  the BEAM exits.

## Building

The Makefile is driven by `elixir_make`. CFLAGS include the ERTS
headers; on macOS, LDFLAGS add `-undefined dynamic_lookup
-flat_namespace` for the shared-library symbol resolution that the
BEAM expects.

The whole file is ~250 LOC of standard POSIX. No third-party
dependencies, no `#ifdef` gymnastics — `tcgetattr` / `tcsetattr` /
`ioctl(TIOCGWINSZ)` / `read(2)` are stable since the 1980s and behave
the same on macOS, Linux, and BSD.

## Verifying hostile conditions

The automated test suite covers the non-tty path (`Termios.open/0`
returns `{:error, :no_tty}` cleanly). Everything else requires a real
terminal and gets verified manually. Walk through these any time you
touch the NIF, the Reader, or the Keeper:

1. **Clean quit.** Run `./scripts/run.sh contacts`. Press Tab to verify
   focus cycling. Press `q` (or Ctrl+C). Confirm: the terminal returns
   to a usable shell prompt with echo working — no need to `stty sane`
   manually.
2. **Crash mid-session.** While the demo is running, in another shell
   tab: `pkill -9 beam.smp` (targeting the demo's PID, not other
   BEAMs). The terminal will be left in raw mode because no graceful
   shutdown ran. Confirm: `stty sane` from that terminal restores
   it — i.e., the kernel-level state is still well-formed and not
   corrupted.
3. **Terminal close (EOF).** Run the demo, then close the terminal
   window directly (Cmd+W). The `read(2)` returns 0; Reader sends
   `{:harlock_tty_lost, :eof}` and stops; supervisor tears down the
   tree. No orphaned BEAM processes — verify with `pgrep beam.smp`.
4. **Resize.** Run the demo, drag the window edge to change size.
   SIGWINCH fires, Keeper queries TIOCGWINSZ via the NIF, sends
   `{:harlock_resize, rows, cols}` to the runtime, and the next frame
   redraws at the new size.

If any of these fail, the failure is the bug. Don't ship workarounds
in the demo — fix it in the framework.
