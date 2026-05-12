#!/usr/bin/env bash
# Run Harlock smoke tests locally with a pseudo-TTY.
# Works on macOS (BSD `script`) and Linux (util-linux `script`).

set -u

cd "$(dirname "$0")/.."

case "$(uname -s)" in
  Darwin|*BSD) run_tty() { script -q /dev/null "$@"; } ;;
  Linux)       run_tty() { script -qc "$*" /dev/null; } ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 2 ;;
esac

smokes=(
  priv/runtime_smoke.exs
  priv/focus_smoke.exs
  priv/sysmon_smoke.exs
)

failed=0
for s in "${smokes[@]}"; do
  printf '\n=== %s ===\n' "$s"
  if run_tty mix run "$s"; then
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
