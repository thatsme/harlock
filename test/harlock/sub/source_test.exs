defmodule Harlock.Sub.SourceTest do
  use ExUnit.Case, async: true

  alias Harlock.Sub

  defmodule SourceApp do
    @moduledoc false
    use Harlock.App

    def init({observer, sub}), do: %{observer: observer, sub: sub, seen: []}

    def subs(%{sub: nil}), do: []
    def subs(%{sub: sub}), do: [sub]

    def update({:from_source, _} = ev, m) do
      send(m.observer, ev)
      %{m | seen: [ev | m.seen]}
    end

    def update({:raw, _} = ev, m) do
      send(m.observer, ev)
      %{m | seen: [ev | m.seen]}
    end

    def update(_ev, m), do: m

    def view(m), do: text("seen: #{length(m.seen)}")
  end

  defp start(sub) do
    h = Harlock.Test.start_app(SourceApp, {self(), sub}, rows: 5, cols: 20)
    pid = Process.whereis(h.runtime)
    on_exit(fn -> if Process.alive?(pid), do: Harlock.Test.stop(h) end)
    {h, pid}
  end

  # The subscribe function runs inside the subscription's own process, so it can
  # publish that pid back for a test to send to — which is the same mechanism
  # Phoenix.PubSub relies on.
  defp announce_self(owner) do
    fn -> send(owner, {:source_pid, self()}) end
  end

  defp await_source_pid do
    assert_receive {:source_pid, pid}, 500
    pid
  end

  describe "forwarding" do
    test "messages received by the source process reach update/2" do
      start(Sub.source(:test, announce_self(self()), &{:raw, &1}))
      source = await_source_pid()

      send(source, :hello)

      assert_receive {:raw, :hello}, 500
    end

    test "a transform shapes the delivered message" do
      start(Sub.source(:test, announce_self(self()), fn msg -> {:from_source, msg} end))
      source = await_source_pid()

      send(source, %{id: 7})

      assert_receive {:from_source, %{id: 7}}, 500
    end

    test "without a transform the message is forwarded as received" do
      start(Sub.source(:test, announce_self(self())))
      source = await_source_pid()

      send(source, {:raw, :verbatim})

      assert_receive {:raw, :verbatim}, 500
    end

    test "several messages arrive in order" do
      start(Sub.source(:test, announce_self(self()), &{:raw, &1}))
      source = await_source_pid()

      for i <- 1..5, do: send(source, i)

      for i <- 1..5, do: assert_receive({:raw, ^i}, 500)
    end
  end

  describe "lifecycle" do
    test "the subscribe function runs in a process distinct from the runtime" do
      {_h, runtime} = start(Sub.source(:test, announce_self(self())))
      source = await_source_pid()

      # Phoenix.PubSub subscribes the calling process, so this separation is the
      # whole point: the subscriber must not be the runtime.
      refute source == runtime
    end

    test "stopping the app takes the source process with it" do
      {h, _runtime} = start(Sub.source(:test, announce_self(self())))
      source = await_source_pid()
      assert Process.alive?(source)

      Harlock.Test.stop(h)

      # linked, so it dies with the runtime — which is what unsubscribes anything
      # scoped to the subscriber's pid
      assert eventually(fn -> not Process.alive?(source) end)
    end

    test "the same key started twice yields one process" do
      # spec identity is by key, so a re-render must not spawn a second
      {_h, runtime} = start(Sub.source(:stable, announce_self(self())))
      _source = await_source_pid()

      subs = runtime |> :sys.get_state() |> Map.fetch!(:subs)
      assert map_size(subs) == 1

      refute_receive {:source_pid, _}, 100
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
