# Harlock

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `harlock` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:harlock, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/harlock>.

## Running examples

The `examples/` directory contains small Harlock apps you can launch
interactively in your terminal:

```sh
./scripts/run.sh counter   # simple counter
./scripts/run.sh sysmon    # live BEAM process monitor
```

Run with no args to see the available examples. Each app prints its key
bindings (typically `q` or `Esc` to quit).

## Smoke tests

The scripts in `priv/*_smoke.exs` exercise the runtime, focus, and sysmon
flows end-to-end and need a pseudo-TTY. To run them locally on macOS or
Linux (no Docker required):

```sh
./scripts/smoke.sh
```

The script wraps each smoke run with `script` so stdin/stdout look like a
real terminal. It picks the right flag syntax for BSD `script` (macOS) vs.
util-linux `script` (Linux) automatically, and exits non-zero if any smoke
fails.

