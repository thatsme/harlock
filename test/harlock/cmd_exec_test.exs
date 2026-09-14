defmodule Harlock.CmdExecTest do
  use ExUnit.Case, async: true

  alias Harlock.Cmd

  # Running a program for real needs a terminal the BEAM controls, which
  # `mix test` does not have; priv/exec_runtime_smoke.exs covers that in a pty.
  # These cover the API and the test backend's stand-in.

  defmodule EditorApp do
    use Harlock.App

    def init(_), do: %{results: []}

    def update({:edit, program, args, opts}, m),
      do: {m, Cmd.exec(program, args, opts) |> Cmd.map(&{:edited, &1})}

    def update({:edit_and_fetch, path}, m) do
      {m,
       Cmd.batch([
         Cmd.exec("vim", [path]) |> Cmd.map(&{:edited, &1}),
         Cmd.from(fn -> :fetched end)
       ])}
    end

    def update({:edited, result}, m), do: %{m | results: m.results ++ [{:edited, result}]}
    def update(:fetched, m), do: %{m | results: m.results ++ [:fetched]}
    def update(_, m), do: m

    def view(m), do: text("#{length(m.results)} results")
  end

  defp results(h), do: Harlock.Test.model(h).results

  # Cmd results arrive asynchronously, after the update that dispatched them.
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  describe "exec/3 arguments" do
    test "builds a cmd from a program, args and options" do
      assert Cmd.exec("vim", ["notes.md"], cd: "/tmp", env: %{"EDITOR" => "vi"})
    end

    test "rejects what cannot be run" do
      assert_raise ArgumentError, ~r/program name/, fn -> Cmd.exec("") end
      assert_raise ArgumentError, ~r/program name/, fn -> Cmd.exec(:vim) end
      assert_raise ArgumentError, ~r/list of strings/, fn -> Cmd.exec("vim", "notes.md") end
      assert_raise ArgumentError, ~r/list of strings/, fn -> Cmd.exec("vim", ["a\0b"]) end

      assert_raise ArgumentError, ~r/unknown or malformed option/, fn ->
        Cmd.exec("vim", [], shell: true)
      end

      assert_raise ArgumentError, ~r/:env entries/, fn -> Cmd.exec("vim", [], env: [{"A", 1}]) end
    end
  end

  describe "under the test backend" do
    test "the :exec stub sees what the app asked for, and its result reaches update/2" do
      test_pid = self()

      stub = fn program, args, opts ->
        send(test_pid, {:ran, program, args, opts})
        {:ok, 3}
      end

      h = Harlock.Test.start_app(EditorApp, nil, exec: stub)

      Harlock.Test.send_event(h, {:edit, "vim", ["notes.md"], [cd: "/work", env: [{"A", "1"}]]})

      assert_receive {:ran, "vim", ["notes.md"], [cd: "/work", env: [{"A", "1"}]]}
      assert eventually(fn -> results(h) == [{:edited, {:ok, 3}}] end)

      Harlock.Test.stop(h)
    end

    test "without a stub every exec reports that there is no terminal" do
      h = Harlock.Test.start_app(EditorApp)

      Harlock.Test.send_event(h, {:edit, "vim", [], []})

      assert eventually(fn -> results(h) == [{:edited, {:error, :no_terminal}}] end)
      Harlock.Test.stop(h)
    end

    test "exec composes with batch and map like any other cmd" do
      h = Harlock.Test.start_app(EditorApp, nil, exec: fn "vim", ["a.md"], [] -> {:ok, 0} end)

      Harlock.Test.send_event(h, {:edit_and_fetch, "a.md"})

      assert eventually(fn ->
               Enum.sort(results(h)) == Enum.sort([{:edited, {:ok, 0}}, :fetched])
             end)

      Harlock.Test.stop(h)
    end
  end
end
