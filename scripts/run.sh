#!/usr/bin/env bash
# Launch a Harlock example app interactively in the current terminal.
# Usage: ./scripts/run.sh <example-name>

set -eu

cd "$(dirname "$0")/.."

list_examples() {
  for f in examples/*.exs; do
    [ -e "$f" ] || continue
    basename "$f" .exs
  done
}

usage() {
  echo "Usage: $0 <example-name>"
  echo
  echo "Available examples:"
  list_examples | sed 's/^/  - /'
  exit 1
}

[ $# -eq 1 ] || usage

name=$1
file="examples/${name}.exs"

if [ ! -f "$file" ]; then
  echo "error: no example named '$name' (expected $file)" >&2
  echo
  echo "Available examples:"
  list_examples | sed 's/^/  - /' >&2
  exit 1
fi

exec mix run "$file" --run
