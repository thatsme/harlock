defmodule Harlock.CmdTest do
  use ExUnit.Case, async: true

  alias Harlock.Cmd

  defmodule CmdApp do
    use Harlock.App

    def init({:with_init_cmd, observer}) do
      cmd = Cmd.from(fn -> :init_ran end) |> Cmd.map(fn r -> {:init_result, r} end)
      {%{observer: observer, log: []}, cmd}
    end

    def init(observer) do
      %{observer: observer, log: []}
    end

    # from + map — single cmd, single result
    def update({:key, {:char, ?f}, []}, m) do
      cmd = Cmd.from(fn -> :hello end) |> Cmd.map(fn r -> {:fetched, r} end)
      {m, cmd}
    end

    # batch of three
    def update({:key, {:char, ?b}, []}, m) do
      cmd =
        Cmd.batch([
          Cmd.from(fn -> :a end) |> Cmd.map(fn r -> {:batched, r} end),
          Cmd.from(fn -> :b end) |> Cmd.map(fn r -> {:batched, r} end),
          Cmd.from(fn -> :c end) |> Cmd.map(fn r -> {:batched, r} end)
        ])

      {m, cmd}
    end

    # crash inside cmd
    def update({:key, {:char, ?x}, []}, m) do
      cmd = Cmd.from(fn -> raise "boom" end) |> Cmd.map(fn r -> {:crashed, r} end)
      {m, cmd}
    end

    # nested map (outer applied after inner)
    def update({:key, {:char, ?m}, []}, m) do
      cmd =
        Cmd.from(fn -> 1 end)
        |> Cmd.map(fn r -> r + 10 end)
        |> Cmd.map(fn r -> {:nested, r} end)

      {m, cmd}
    end

    # quit-with-cmd
    def update({:key, {:char, ?Q}, []}, m) do
      observer = m.observer

      cmd =
        Cmd.from(fn ->
          send(observer, :quit_cmd_ran)
          :ok
        end)

      {:quit, cmd}
    end

    # Result-handling clauses — forward to observer for assertion.
    def update({:fetched, _} = msg, m), do: notify(m, msg)
    def update({:batched, _} = msg, m), do: notify(m, msg)
    def update({:crashed, _} = msg, m), do: notify(m, msg)
    def update({:nested, _} = msg, m), do: notify(m, msg)
    def update({:init_result, _} = msg, m), do: notify(m, msg)

    def update(_, m), do: m

    def view(_), do: text("cmd test")

    defp notify(%{observer: obs} = m, msg) do
      send(obs, msg)
      %{m | log: [msg | m.log]}
    end
  end

  describe "Cmd.from" do
    test "delivers the function's return value as an event" do
      h = Harlock.Test.start_app(CmdApp, self(), rows: 5, cols: 20)

      Harlock.Test.send_key(h, {:char, ?f})

      assert_receive {:fetched, :hello}, 500
      Harlock.Test.stop(h)
    end
  end

  describe "Cmd.batch" do
    test "dispatches all child cmds" do
      h = Harlock.Test.start_app(CmdApp, self(), rows: 5, cols: 20)

      Harlock.Test.send_key(h, {:char, ?b})

      results =
        for _ <- 1..3 do
          assert_receive {:batched, value}, 500
          value
        end

      assert Enum.sort(results) == [:a, :b, :c]
      Harlock.Test.stop(h)
    end
  end

  describe "Cmd.map" do
    test "nested maps apply inner-first, outer-last" do
      h = Harlock.Test.start_app(CmdApp, self(), rows: 5, cols: 20)

      Harlock.Test.send_key(h, {:char, ?m})

      assert_receive {:nested, 11}, 500
      Harlock.Test.stop(h)
    end
  end

  describe "cmd crashes" do
    test "are caught and delivered as {:cmd_error, _}" do
      h = Harlock.Test.start_app(CmdApp, self(), rows: 5, cols: 20)

      Harlock.Test.send_key(h, {:char, ?x})

      assert_receive {:crashed, {:cmd_error, {:exception, %RuntimeError{message: "boom"}}}}, 500
      Harlock.Test.stop(h)
    end

    test "do not take down the runtime" do
      h = Harlock.Test.start_app(CmdApp, self(), rows: 5, cols: 20)

      Harlock.Test.send_key(h, {:char, ?x})
      assert_receive {:crashed, {:cmd_error, _}}, 500

      # Runtime still alive — a follow-up cmd still works.
      Harlock.Test.send_key(h, {:char, ?f})
      assert_receive {:fetched, :hello}, 500

      Harlock.Test.stop(h)
    end
  end

  describe "init/1 returning {model, cmd}" do
    test "dispatches the cmd after the first render" do
      h = Harlock.Test.start_app(CmdApp, {:with_init_cmd, self()}, rows: 5, cols: 20)

      assert_receive {:init_result, :init_ran}, 500
      Harlock.Test.stop(h)
    end
  end

  describe "quit-with-cmd" do
    test "dispatches the cmd before the runtime exits" do
      h = Harlock.Test.start_app(CmdApp, self(), rows: 5, cols: 20)

      Harlock.Test.send_key(h, {:char, ?Q})

      assert_receive :quit_cmd_ran, 500
      assert Harlock.Test.quit?(h)

      Harlock.Test.stop(h)
    end
  end
end
