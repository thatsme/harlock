defmodule HarlockTest do
  use ExUnit.Case, async: true

  # Top-level Harlock module currently only exposes smoke functions that
  # require /dev/tty, so there's nothing to assert here that wouldn't open a
  # real terminal. Real tests live under test/harlock/*.
end
