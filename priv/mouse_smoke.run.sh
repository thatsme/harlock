#!/bin/sh
# Runs priv/mouse_smoke.exs inside a second pty whose output is recorded to
# $HARLOCK_SMOKE_DIR/tty.log, flushed as it is written, so the smoke test can
# read back the escape sequences its app sent to the terminal.

log="$HARLOCK_SMOKE_DIR/tty.log"
: > "$log"

case "$(uname -s)" in
  Darwin|*BSD) exec script -q -F "$log" mix run "$1" ;;
  Linux)       exec script -q -f -e -c "mix run $1" "$log" ;;
esac
