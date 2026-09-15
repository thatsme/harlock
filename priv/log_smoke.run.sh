#!/bin/sh
# Runs priv/log_smoke.exs with standard output going to a file. Harlock draws on
# /dev/tty, not standard output, so the app still has its terminal, while
# everything the console logger writes lands in $HARLOCK_SMOKE_DIR/stdout for
# the script to inspect: nothing while an app runs, all of it after.

exec mix run "$1" > "$HARLOCK_SMOKE_DIR/stdout"
