#!/bin/sh
# Runs priv/suspend_smoke.exs the way a user's shell would: as a job under job
# control, so that the app's SIGTSTP stops it and `fg` resumes it. While the
# app is stopped this records what the shell got back — the job's stop and the
# terminal settings — in $HARLOCK_SMOKE_DIR for the smoke test to check.
#
# A stopped job's status is 128 + the signal: SIGTSTP is 18 on macOS, 20 on
# Linux.

# An interactive bash (-i, --norc): macOS's bash 3.2 with `set -m` alone runs
# the job in its own process group but never notices it stopping, so nothing
# would run fg.
exec bash --norc -i -c '
mix run "$1"
status=$?
while [ "$status" -eq 146 ] || [ "$status" -eq 148 ]; do
  touch "$HARLOCK_SMOKE_DIR/stopped"
  stty -a > "$HARLOCK_SMOKE_DIR/stty_while_stopped"
  sleep 1
  fg %1 > /dev/null
  status=$?
done
exit "$status"
' bash "$1"
