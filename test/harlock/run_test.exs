defmodule Harlock.RunTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  # Termios.open/0 reports :no_tty here, so this exercises the start-failure
  # path. What happens once an app is running — its crash, its quit, other
  # links dying — needs a real terminal and is in priv/crash_smoke.exs.
  @moduletag :nif

  defmodule App do
    use Harlock.App
    def init(_), do: %{}
    def update(_, m), do: m
    def view(_), do: text("never drawn")
  end

  test "a supervisor that cannot start is an error, with no trace left in the caller" do
    capture_io(:stderr, fn ->
      assert {:error, _reason} = Harlock.run(App)
    end)

    assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "a caller that was already trapping exits keeps doing so" do
    Process.flag(:trap_exit, true)

    capture_io(:stderr, fn ->
      assert {:error, _reason} = Harlock.run(App)
    end)

    assert Process.info(self(), :trap_exit) == {:trap_exit, true}
    assert Process.info(self(), :messages) == {:messages, []}
  end
end
