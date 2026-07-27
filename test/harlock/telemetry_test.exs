defmodule Harlock.TelemetryTest do
  use ExUnit.Case, async: false

  # async: false because :telemetry handlers are process-global, and these
  # tests attach handlers that catch events from any test running
  # concurrently.

  defmodule TickApp do
    use Harlock.App

    def init(_), do: %{n: 0}

    def update({:key, {:char, ?+}, []}, m), do: %{m | n: m.n + 1}

    def update({:key, {:char, ?c}, []}, m) do
      cmd = Cmd.from(fn -> :hello end)
      {m, cmd}
    end

    def update(_, m), do: m

    def view(m), do: text("count: #{m.n}")
  end

  setup do
    parent = self()
    handler_id = "test-#{inspect(self())}"

    :telemetry.attach_many(
      handler_id,
      [
        [:harlock, :frame, :render, :stop],
        [:harlock, :input, :dispatch, :stop],
        [:harlock, :cmd, :dispatch],
        [:harlock, :cmd, :complete]
      ],
      fn event, measurements, metadata, _ ->
        send(parent, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "frame render emits :stop with duration + dimensions" do
    h = Harlock.Test.start_app(TickApp, nil, rows: 5, cols: 20)

    assert_received {:telemetry, [:harlock, :frame, :render, :stop], measurements, metadata}
    # Durations are :native units from :telemetry.span/3. A host with a coarse
    # monotonic clock (Windows) legitimately reports 0 when the work finishes
    # inside one tick, so the contract is a non-negative integer — asserting
    # > 0 would be asserting the host clock is fast, not that we measured.
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert metadata.rows == 5
    assert metadata.cols == 20
    assert metadata.app == TickApp
    assert is_boolean(metadata.dirty)

    Harlock.Test.stop(h)
  end

  test "input dispatch emits :stop with event + focused metadata" do
    h = Harlock.Test.start_app(TickApp, nil, rows: 5, cols: 20)

    # Drain the initial-render event
    flush_telemetry()

    Harlock.Test.send_key(h, {:char, ?+})

    assert_receive {:telemetry, [:harlock, :input, :dispatch, :stop], measurements, metadata},
                   500

    # Durations are :native units from :telemetry.span/3. A host with a coarse
    # monotonic clock (Windows) legitimately reports 0 when the work finishes
    # inside one tick, so the contract is a non-negative integer — asserting
    # > 0 would be asserting the host clock is fast, not that we measured.
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert metadata.event == {:key, {:char, ?+}, []}
    assert metadata.app == TickApp

    Harlock.Test.stop(h)
  end

  test "cmd dispatch + complete events with status" do
    h = Harlock.Test.start_app(TickApp, nil, rows: 5, cols: 20)
    flush_telemetry()

    Harlock.Test.send_key(h, {:char, ?c})

    assert_receive {:telemetry, [:harlock, :cmd, :dispatch], %{count: 1}, %{kind: :fun}}, 500
    assert_receive {:telemetry, [:harlock, :cmd, :complete], measurements, metadata}, 500
    # Durations are :native units from :telemetry.span/3. A host with a coarse
    # monotonic clock (Windows) legitimately reports 0 when the work finishes
    # inside one tick, so the contract is a non-negative integer — asserting
    # > 0 would be asserting the host clock is fast, not that we measured.
    assert is_integer(measurements.duration) and measurements.duration >= 0
    assert metadata.status == :ok

    Harlock.Test.stop(h)
  end

  defp flush_telemetry do
    receive do
      {:telemetry, _, _, _} -> flush_telemetry()
    after
      0 -> :ok
    end
  end
end
