#!/usr/bin/env bash
# Run Harlock smoke tests locally with a pseudo-TTY.
# Works on macOS (BSD `script`) and Linux (util-linux `script`).

set -u

cd "$(dirname "$0")/.."

case "$(uname -s)" in
  Darwin|*BSD) run_tty() { script -q /dev/null "$@"; } ;;
  Linux)       run_tty() { script -qec "$*" /dev/null; } ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 2 ;;
esac

smokes=(
  priv/runtime_smoke.exs
  priv/focus_smoke.exs
  priv/resize_smoke.exs
  priv/exec_native_smoke.exs
  priv/exec_runtime_smoke.exs
  priv/exec_input_smoke.exs
  priv/crash_smoke.exs
  priv/sysmon_smoke.exs
  priv/contacts_smoke.exs
)

# A smoke test that needs typed input has a <name>.drive.sh next to it, whose
# output is piped into the pty. Each test gets its own directory in
# HARLOCK_SMOKE_DIR for the two sides to coordinate through.
run_smoke() {
  HARLOCK_SMOKE_DIR="$(mktemp -d)"
  export HARLOCK_SMOKE_DIR
  driver="${1%.exs}.drive.sh"

  if [ -x "$driver" ]; then
    "$driver" | run_tty mix run "$1"
  else
    run_tty mix run "$1"
  fi
  status=$?

  rm -rf "$HARLOCK_SMOKE_DIR"
  return $status
}

failed=0
for s in "${smokes[@]}"; do
  printf '\n=== %s ===\n' "$s"
  if run_smoke "$s"; then
    printf '\n[PASS] %s\n' "$s"
  else
    printf '\n[FAIL] %s\n' "$s"
    failed=$((failed + 1))
  fi
done

printf '\n----\n'
if [ "$failed" -eq 0 ]; then
  echo "all smoke tests passed"
  exit 0
else
  echo "$failed smoke test(s) failed"
  exit 1
fi
