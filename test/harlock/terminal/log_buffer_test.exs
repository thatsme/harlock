defmodule Harlock.Terminal.LogBufferTest do
  # async: false — capture/release change :logger's global handler config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Harlock.Terminal.LogBuffer

  defmodule Formatter do
    def format(%{msg: {:string, text}}, :plain), do: [text, "\n"]
    def format(_event, :raises), do: raise("formatter bug")
  end

  defp event(text, level \\ :info), do: %{level: level, msg: {:string, text}, meta: %{}}

  describe "push/2 and replay/1" do
    test "replays events oldest first, each through its own formatter" do
      buffer =
        LogBuffer.new()
        |> LogBuffer.push({{Formatter, :plain}, event("one")})
        |> LogBuffer.push({{Formatter, :plain}, event("two")})

      assert capture_io(fn -> LogBuffer.replay(buffer) end) == "one\ntwo\n"
    end

    test "keeps the most recent 500 and says how many it dropped" do
      buffer =
        Enum.reduce(1..503, LogBuffer.new(), fn n, acc ->
          LogBuffer.push(acc, {{Formatter, :plain}, event("line #{n}")})
        end)

      output = capture_io(fn -> LogBuffer.replay(buffer) end)

      assert output =~ "… 3 earlier log events not kept\n"
      refute output =~ "line 3\n"
      assert output =~ "line 4\nline 5\n"
      assert String.ends_with?(output, "line 503\n")
    end

    test "collects events still in the mailbox before replaying" do
      send(self(), {:harlock_log, {Formatter, :plain}, event("late")})
      buffer = LogBuffer.push(LogBuffer.new(), {{Formatter, :plain}, event("early")})

      assert capture_io(fn -> LogBuffer.replay(buffer) end) == "early\nlate\n"
    end

    test "a formatter that raises does not stop the rest" do
      buffer =
        LogBuffer.new()
        |> LogBuffer.push({{Formatter, :raises}, event("broken", :error)})
        |> LogBuffer.push({{Formatter, :plain}, event("fine")})

      output = capture_io(fn -> LogBuffer.replay(buffer) end)
      assert output =~ ":error"
      assert String.ends_with?(output, "fine\n")
    end
  end

  describe "capture/1 and release/1" do
    # Released in on_exit too, so a failed assertion cannot leave the console
    # handlers of the whole test run muted.
    setup do
      level = :logger.get_handler_config(:default)

      on_exit(fn ->
        with {:ok, %{level: level}} <- level,
             do: :logger.update_handler_config(:default, :level, level)
      end)

      :ok =
        :logger.add_handler(:log_buffer_test_console, :logger_std_h, %{
          level: :warning,
          config: %{type: :standard_io}
        })

      on_exit(fn ->
        :logger.remove_handler(:harlock_log_buffer_log_buffer_test_console)
        :logger.remove_handler(:log_buffer_test_console)
      end)
    end

    test "mute console handlers, mirror their events here, and put them back" do
      captured = LogBuffer.capture(self())

      assert {:ok, %{level: :none}} = :logger.get_handler_config(:log_buffer_test_console)

      :logger.warning("mirrored")
      assert_receive {:harlock_log, _formatter, %{msg: {:string, "mirrored"}}}

      :ok = LogBuffer.release(captured)

      assert {:ok, %{level: :warning}} = :logger.get_handler_config(:log_buffer_test_console)

      refute Enum.any?(
               :logger.get_handler_ids(),
               &(&1 == :harlock_log_buffer_log_buffer_test_console)
             )

      # Released: nothing more arrives.
      :logger.warning("not mirrored")
      refute_receive {:harlock_log, _, %{msg: {:string, "not mirrored"}}}, 50
    end

    test "mirror at the console handler's level" do
      # The test run's own console handler takes :info; this one is about ours.
      :ok = :logger.update_handler_config(:default, :level, :warning)
      captured = LogBuffer.capture(self())
      :logger.info("below the handler's level")
      :ok = LogBuffer.release(captured)

      refute_receive {:harlock_log, _, %{msg: {:string, "below the handler's level"}}}, 50
    end
  end
end
