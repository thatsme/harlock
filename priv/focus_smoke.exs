# Verifies focus cycling end-to-end: starts an app with 3 focusable elements,
# sends Tab/Shift-Tab, checks focused state via :sys.get_state, then quits.

defmodule FocusApp do
  use Harlock.App

  def init(_), do: %{}

  def update({:key, {:char, ?q}, []}, _), do: :quit
  def update(_, m), do: m

  def view(_m) do
    vbox(
      children: [
        text("a", focusable: :a),
        text("b", focusable: :b),
        text("c", focusable: :c)
      ]
    )
  end
end

parent = self()

_ =
  spawn(fn ->
    result = Harlock.run(FocusApp)
    send(parent, {:done, result})
  end)

Process.sleep(400)

runtime = Process.whereis(:"Elixir.Harlock.App.Supervisor.Runtime")
unless runtime, do: (IO.puts(:stderr, "runtime not registered"); System.halt(1))

current = fn ->
  :sys.get_state(runtime).focused
end

send_key = fn key, mods -> send(runtime, {:harlock_event, {:key, key, mods}}) end

initial = current.()
IO.puts("initial focus: #{inspect(initial)}")

send_key.(:tab, [])
Process.sleep(50)
after_tab1 = current.()
IO.puts("after Tab: #{inspect(after_tab1)}")

send_key.(:tab, [])
Process.sleep(50)
after_tab2 = current.()
IO.puts("after Tab: #{inspect(after_tab2)}")

send_key.(:tab, [])
Process.sleep(50)
after_tab3 = current.()
IO.puts("after Tab (should wrap): #{inspect(after_tab3)}")

send_key.(:tab, [:shift])
Process.sleep(50)
after_shift = current.()
IO.puts("after Shift-Tab: #{inspect(after_shift)}")

send_key.({:char, ?q}, [])

result =
  receive do
    {:done, r} -> r
  after
    3_000 -> :timeout
  end

cond do
  initial == :a and after_tab1 == :b and after_tab2 == :c and
    after_tab3 == :a and after_shift == :c and result == {:ok, :normal} ->
    IO.puts("PASS")
    System.halt(0)

  true ->
    IO.puts("FAIL: result=#{inspect(result)}")
    System.halt(1)
end
