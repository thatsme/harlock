defmodule Harlock.Sub.LoggerTest do
  # Not async: adds global :logger handlers.
  use ExUnit.Case, async: false

  require Logger

  alias Harlock.Sub

  defmodule LogApp do
    @moduledoc false
    use Harlock.App

    alias Harlock.Sub.Logger, as: LoggerSub

    def init({observer, sub}), do: %{observer: observer, sub: sub, entries: []}

    def subs(%{sub: nil}), do: []
    def subs(%{sub: sub}), do: [sub]

    # Deliberately does not log: a :logger handler runs in the logging process,
    # so logging from here would be delivered right back and loop.
    def update({:log, entry}, m) do
      send(m.observer, {:entry, entry.level, LoggerSub.text(entry), entry.meta})
      %{m | entries: [entry | m.entries]}
    end

    def update({:custom, _} = ev, m) do
      send(m.observer, ev)
      m
    end

    def update(_ev, m), do: m

    def view(m), do: text("entries: #{length(m.entries)}")
  end

  defp start(sub) do
    h = Harlock.Test.start_app(LogApp, {self(), sub}, rows: 5, cols: 20)
    pid = Process.whereis(h.runtime)
    on_exit(fn -> if Process.alive?(pid), do: Harlock.Test.stop(h) end)
    {h, pid}
  end

  defp handler_ids do
    :logger.get_handler_ids()
    |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "harlock_log_"))
  end

  # The handler is added during the first render, which start_app/3 does not wait
  # for — so logging immediately after starting races the add, exactly as it does
  # for Sub.telemetry.
  defp await_handler(count) do
    assert eventually(fn -> length(handler_ids()) == count end),
           "expected #{count} harlock log handlers, saw #{inspect(handler_ids())}"
  end

  # The handler receives every log event at its level, not only the one a test
  # emitted — anything the library or a dependency logs arrives too. A bare
  # assert_receive would bind the first entry that matched the shape and then
  # fail on the content, so search the mailbox for the entry actually wanted.
  defp assert_entry(level, needle, timeout \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    assert_entry_by(level, needle, deadline)
  end

  defp assert_entry_by(level, needle, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {:entry, ^level, message, meta} ->
        if String.contains?(message, needle),
          do: {message, meta},
          else: assert_entry_by(level, needle, deadline)
    after
      max(remaining, 0) ->
        flunk("no #{level} entry containing #{inspect(needle)} within the timeout")
    end
  end

  setup do
    # Any handler left behind by an earlier test would deliver into a dead
    # runtime and skew the counts here.
    on_exit(fn -> Enum.each(handler_ids(), &:logger.remove_handler/1) end)
    :ok
  end

  describe "delivery" do
    test "a log call reaches update/2, rendered through text/1" do
      start(Sub.logger(level: :info))
      await_handler(1)

      Logger.info("hello from the test")

      assert {message, _meta} = assert_entry(:info, "hello from the test")
      assert message =~ "hello from the test"
    end

    test "level filtering happens before the app sees anything" do
      start(Sub.logger(level: :warning))
      await_handler(1)

      Logger.debug("too quiet")
      Logger.info("still too quiet")
      Logger.warning("loud enough")

      assert_entry(:warning, "loud enough")

      refute_receive {:entry, :debug, _, _}, 100
      refute_receive {:entry, :info, _, _}, 100
    end

    test "metadata is delivered in full by default" do
      start(Sub.logger(level: :info))
      await_handler(1)

      Logger.info("with metadata")

      # :logger itself populates :pid, :time, :gl and :domain on every event.
      # Notably it does *not* populate :module or :line — Elixir adds those at
      # formatting time, not into the raw event — so a metadata search feature
      # cannot assume they are present.
      assert {_message, meta} = assert_entry(:info, "with metadata")
      assert meta[:pid] == self()
      assert is_integer(meta[:time])
    end

    test "metadata can be narrowed to bound what is copied" do
      start(Sub.logger(level: :info, metadata: [:pid]))
      await_handler(1)

      Logger.info("narrowed metadata")

      assert {_message, meta} = assert_entry(:info, "narrowed metadata")
      assert meta[:pid] == self()
      # dropped rather than delivered — every entry is copied into the runtime's
      # mailbox, and log metadata can carry stacktraces and large structs
      refute Map.has_key?(meta, :time)
      refute Map.has_key?(meta, :domain)
    end

    test "a transform replaces the delivered message" do
      start(Sub.logger(level: :info, transform: &{:custom, &1.level}))
      await_handler(1)

      Logger.error("whatever")

      assert_receive {:custom, :error}, 500
    end
  end

  describe "text/1" do
    alias Harlock.Sub.Logger, as: L

    test "renders the three shapes :logger produces" do
      assert L.text({:string, ["a", "b"]}) == "ab"
      assert L.text({~c"n=~p", [42]}) == "n=42"
      assert L.text(%{level: :info, msg: {:string, "via entry"}, meta: %{}}) == "via entry"
    end

    test "renders a report without raising" do
      rendered = L.text({:report, %{a: 1}})
      assert is_binary(rendered)
      assert rendered =~ "1"
    end

    test "a malformed message degrades instead of crashing" do
      # too few arguments for the format string — :io_lib.format would raise, and
      # a log viewer that dies on one bad entry is worse than one showing a
      # placeholder
      rendered = L.text({~c"~p ~p", [1]})
      assert is_binary(rendered)
    end
  end

  describe "handler lifecycle" do
    test "stopping the app removes the handler" do
      {h, _pid} = start(Sub.logger(level: :info))
      await_handler(1)

      Harlock.Test.stop(h)

      # linked owner process goes down with the runtime and removes the handler.
      # Left attached it would deliver into a dead pid for the life of the VM.
      assert eventually(fn -> handler_ids() == [] end)
    end

    test "two apps get separate handlers" do
      {a, _} = start(Sub.logger(level: :info))
      {_b, _} = start(Sub.logger(level: :info))
      await_handler(2)

      Harlock.Test.stop(a)

      assert eventually(fn -> length(handler_ids()) == 1 end)
    end

    test "logging still works normally after the app stops" do
      {h, _} = start(Sub.logger(level: :info))
      await_handler(1)
      Harlock.Test.stop(h)
      assert eventually(fn -> handler_ids() == [] end)

      # a removed handler must not have broken the default one
      assert Logger.info("after teardown") == :ok
    end
  end

  defp eventually(fun, tries \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end
end
