#!/bin/sh
# Keystrokes for priv/exec_input_smoke.exs. scripts/smoke.sh pipes this
# script's output into the pty, so what it prints is what the terminal
# receives as typed input. It waits for each marker file before typing.

dir="$HARLOCK_SMOKE_DIR"

wait_for() {
  i=0
  while [ ! -e "$dir/$1" ]; do
    sleep 0.1
    i=$((i + 1))
    if [ "$i" -gt 300 ]; then
      echo "driver: timed out waiting for $1" >&2
      exit 1
    fi
  done
  sleep 0.3
}

wait_for app_ready && printf 'r'
wait_for program_ready && printf 'typed into the program\r'
wait_for app_back && printf 'z'
wait_for done
