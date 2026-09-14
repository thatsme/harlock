Code.require_file("examples/contacts.exs")

# Verify ContactsApp boots under the Test backend and that Up / Down move the
# selection once the list has focus. The list is a focusable table, so the
# arrows are routed by the runtime and arrive as {:harlock_select, ...}.

h = Harlock.Test.start_app(ContactsApp, nil, rows: 30, cols: 100)

frame = Harlock.Test.render(h)

unless String.contains?(frame, "Contacts (5)") do
  IO.puts(:stderr, "FAIL: contact list not in initial render")
  IO.puts(frame)
  System.halt(1)
end

# Search starts focused; Tab moves to the list.
Harlock.Test.send_key(h, :tab)
Harlock.Test.render(h)

step = fn key, expected, label ->
  Harlock.Test.send_key(h, key)
  frame = Harlock.Test.render(h)
  actual = Harlock.Test.model(h).focused_id

  unless actual == expected do
    IO.puts(:stderr, "FAIL: #{label}: focused_id #{inspect(actual)}, expected #{expected}")
    IO.puts(frame)
    System.halt(1)
  end
end

step.(:down, 2, "Down")
step.(:down, 3, "second Down")
step.(:up, 2, "Up")
step.(:end, 5, "End")
step.(:home, 1, "Home")

frame = Harlock.Test.render(h)

unless String.contains?(frame, "Details — Alice Wong") do
  IO.puts(:stderr, "FAIL: detail pane did not follow the selection")
  IO.puts(frame)
  System.halt(1)
end

Harlock.Test.send_key(h, {:char, ?q})

unless Harlock.Test.quit?(h) do
  IO.puts(:stderr, "FAIL: runtime did not exit on q")
  System.halt(1)
end

Harlock.Test.stop(h)

IO.puts("PASS")
System.halt(0)
