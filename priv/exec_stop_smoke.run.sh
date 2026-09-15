#!/bin/sh
# Runs priv/exec_stop_smoke.exs as a job under an interactive bash, so that a
# program it starts with Cmd.exec can stop and take the whole job with it. While
# the job is stopped this records what the shell sees — the job's stop, and the
# state of the stopped program — in $HARLOCK_SMOKE_DIR, then runs `fg`.
#
# A stopped job's status is 128 + the signal: SIGTSTP is 18 on macOS, 20 on
# Linux. An interactive bash (-i) is needed: macOS's bash 3.2 with only `set -m`
# never notices a job stopping.

exec bash --norc -i -c '
mix run "$1"
status=$?
while [ "$status" -eq 146 ] || [ "$status" -eq 148 ]; do
  touch "$HARLOCK_SMOKE_DIR/job_stopped"
  if [ -f "$HARLOCK_SMOKE_DIR/program_pid" ]; then
    ps -o stat= -p "$(cat "$HARLOCK_SMOKE_DIR/program_pid")" > "$HARLOCK_SMOKE_DIR/program_state"
  fi
  sleep 1
  fg %1 > /dev/null
  status=$?
done
exit "$status"
' bash "$1"
