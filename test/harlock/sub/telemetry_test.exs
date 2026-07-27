defmodule Harlock.Sub.TelemetryTest do
  # Not async: attaches global :telemetry handlers.
  use ExUnit.Case, async: false

  alias Harlock.Sub

  defmodule TelemetryApp do
    @moduledoc false
    use Harlock.App

    def init({observer, sub}), do: %{observer: observer, sub: sub, events: []}

    def subs(%{sub: nil}), do: []
    def subs(%{sub: sub}), do: [sub]

    def update({:tagged, _} = ev, m) do
      send(m.observer, ev)
      %{m | events: [ev | m.events]}
    end

    def update({:raw, _, _} = ev, m) do
      send(m.observer, ev)
      %{m | events: [ev | m.events]}
    end

    def update(_ev, m), do: m

    def view(m), do: text("events: #{length(m.events)}")
  end

  # h.runtime is a registered name, but the handler id carries the runtime's pid
  # (the process the handler sends to), so tests need the pid — and need it
  # captured before stopping, since the name unregisters.
  defp start(sub) do
    h = Harlock.Test.start_app(TelemetryApp, {self(), sub}, rows: 5, cols: 20)
    pid = Process.whereis(h.runtime)
    on_exit(fn -> if Process.alive?(pid), do: Harlock.Test.stop(h) end)
    {h, pid}
  end

  defp attached?(events, runtime_pid) do
    :telemetry.list_handlers(events)
    |> Enum.any?(&match?(%{id: {Harlock.Sub.Telemetry, _, ^runtime_pid}}, &1))
  end

  describe "delivery" do
    test "an emitted event reaches update/2 through the transform" do
      start(Sub.telemetry([:demo, :one], &{:tagged, &1.value}))

      :telemetry.execute([:demo, :one], %{value: 42}, %{})

      assert_receive {:tagged, 42}, 500
    end

    test "a 3-arity transform sees the event name and metadata" do
      start(
        Sub.telemetry(
          [:demo, :three],
          fn event, measurements, meta -> {:raw, List.last(event), {measurements.n, meta.who}} end
        )
      )

      :telemetry.execute([:demo, :three], %{n: 7}, %{who: :worker})

      assert_receive {:raw, :three, {7, :worker}}, 500
    end

    test "several event names can share one subscription" do
      start(
        Sub.telemetry(
          [[:demo, :a], [:demo, :b]],
          fn event, _m, _md -> {:raw, List.last(event), nil} end
        )
      )

      :telemetry.execute([:demo, :a], %{}, %{})
      :telemetry.execute([:demo, :b], %{}, %{})

      assert_receive {:raw, :a, nil}, 500
      assert_receive {:raw, :b, nil}, 500
    end

    test "an unsubscribed event is not delivered" do
      start(Sub.telemetry([:demo, :wanted], &{:tagged, &1.value}))

      :telemetry.execute([:demo, :unwanted], %{value: 1}, %{})

      refute_receive {:tagged, _}, 200
    end
  end

  describe "handler lifecycle" do
    test "the handler is attached while the app runs" do
      {_h, runtime} = start(Sub.telemetry([:demo, :live], &{:tagged, &1.value}))

      # subs/1 runs on render, so the handler exists by the time the app is up
      assert attached?([:demo, :live], runtime)
    end

    test "stopping the app detaches the handler" do
      {h, runtime} = start(Sub.telemetry([:demo, :cleanup], &{:tagged, &1.value}))
      assert attached?([:demo, :cleanup], runtime)

      Harlock.Test.stop(h)

      # the owning process is linked, so it goes down with the runtime and
      # detaches on the way out. Without that, a handler would outlive the app
      # and keep sending to a dead pid forever — send/2 does not raise, so
      # :telemetry would never notice and drop it.
      assert eventually(fn -> not attached?([:demo, :cleanup], runtime) end)
    end

    test "the handler id includes the runtime, so two apps do not collide" do
      {a, a_pid} = start(Sub.telemetry([:demo, :shared], &{:tagged, &1.value}))
      {_b, b_pid} = start(Sub.telemetry([:demo, :shared], &{:tagged, &1.value}))

      assert attached?([:demo, :shared], a_pid)
      assert attached?([:demo, :shared], b_pid)

      Harlock.Test.stop(a)

      # stopping one must leave the other's subscription working
      assert eventually(fn -> not attached?([:demo, :shared], a_pid) end)
      assert attached?([:demo, :shared], b_pid)

      :telemetry.execute([:demo, :shared], %{value: 9}, %{})
      assert_receive {:tagged, 9}, 500
    end
  end

  describe "spec identity" do
    test "a stable transform does not churn the subscription across renders" do
      {_h, runtime} = start(Sub.telemetry([:demo, :stable], &{:tagged, &1.value}))

      owner = runtime |> :sys.get_state() |> Map.fetch!(:subs) |> Map.values() |> hd()

      # force more renders; the sub must survive rather than be restarted
      :telemetry.execute([:demo, :stable], %{value: 1}, %{})
      assert_receive {:tagged, 1}, 500
      :telemetry.execute([:demo, :stable], %{value: 2}, %{})
      assert_receive {:tagged, 2}, 500

      same = runtime |> :sys.get_state() |> Map.fetch!(:subs) |> Map.values() |> hd()
      assert same == owner
      assert Process.alive?(owner)
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
