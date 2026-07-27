# The termios NIF is POSIX-only and needs a C toolchain to build. Where it
# isn't present (Windows, or HARLOCK_SKIP_NIF=1) every NIF stub raises
# :nif_not_loaded, so exclude the tests that genuinely need it instead of
# failing the whole run. Everything else in Harlock is pure Elixir — the
# renderer, layout, widgets, parser, and the :test backend all run anywhere.
#
# Probing the real call is deliberate: it asserts what the suite depends on
# (an NIF that is loaded) rather than what the build intended.
nif_loaded? =
  try do
    Harlock.Terminal.Termios.open()
    true
  rescue
    ErlangError -> false
  end

# On a host where the NIF was meant to build, a missing NIF is a build failure,
# not a reason to quietly drop coverage. Without this, a broken Makefile or C
# toolchain on CI would turn into a green run with [:nif] silently excluded.
if not nif_loaded? and not Harlock.MixProject.skip_nif?() do
  raise """
  The termios NIF is expected to build on this host but is not loaded.

  This is a build failure, not a skippable condition. Check the C toolchain
  and `make all`. To run the suite without the NIF deliberately, set
  HARLOCK_SKIP_NIF=1.
  """
end

unless nif_loaded? do
  IO.puts(:stderr, "termios NIF not built for this host — excluding [:nif] tests")
end

ExUnit.start(exclude: if(nif_loaded?, do: [], else: [:nif]))
