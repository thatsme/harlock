defmodule Harlock.Terminal.TermiosTest do
  use ExUnit.Case, async: true

  # Needs the built NIF; skipped on hosts without a C toolchain. See
  # test_helper.exs.
  @moduletag :nif

  alias Harlock.Terminal.Termios

  describe "open/0 in non-tty environments" do
    test "returns {:error, :no_tty} gracefully" do
      # When mix test runs, the BEAM has no controlling terminal (output is
      # piped). The NIF must surface this as a clean :no_tty error so apps
      # can detect CI / non-interactive contexts and refuse cleanly rather
      # than crashing on a tcsetattr or read call.
      assert Termios.open() == {:error, :no_tty}
    end
  end

  # All other NIF behaviors (arm_select, read_nonblock, SIGWINCH-driven
  # winsize, EOF on tty close, resource destructor cleanup) require a real
  # /dev/tty and are verified through the manual checklist in
  # `c_src/README.md` + the hostile-conditions section of `scripts/run.sh`.
end
