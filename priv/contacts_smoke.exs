Code.require_file("examples/contacts.exs")

# Verify ContactsApp boots under the Test backend; that typing into the search
# box filters the list; that Up / Down move the selection once the list has
# focus; and that the add dialog takes typed input and saves on Enter. The
# inputs and the list are routed widgets, so all of this arrives as
# {:harlock_edit, ...}, {:harlock_submit, ...} and {:harlock_select, ...} —
# an example still matching raw keys for them would fail here.

h = Harlock.Test.start_app(ContactsApp, nil, [rows: 30, cols: 100] ++ ContactsApp.run_opts())

frame = Harlock.Test.render(h)

unless String.contains?(frame, "Contacts (5)") do
  IO.puts(:stderr, "FAIL: contact list not in initial render")
  IO.puts(frame)
  System.halt(1)
end

# Search starts focused: typing filters.
for c <- ~c"bob", do: Harlock.Test.send_key(h, {:char, c})

unless String.contains?(Harlock.Test.render(h), "Contacts (1)") do
  IO.puts(:stderr, "FAIL: typing into the search box did not filter the list")
  IO.puts(Harlock.Test.render(h))
  System.halt(1)
end

for _ <- 1..3, do: Harlock.Test.send_key(h, :backspace)

unless String.contains?(Harlock.Test.render(h), "Contacts (5)") do
  IO.puts(:stderr, "FAIL: clearing the search box did not restore the list")
  System.halt(1)
end

# Tab moves to the list.
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

# Add dialog: `a` opens it, typing fills the focused name field, Enter saves.
Harlock.Test.send_key(h, {:char, ?a})
for c <- ~c"Zed", do: Harlock.Test.send_key(h, {:char, c})

unless Harlock.Test.model(h).modal && Harlock.Test.model(h).modal.name == "Zed" do
  IO.puts(:stderr, "FAIL: typing into the dialog's name field did nothing")
  System.halt(1)
end

Harlock.Test.send_key(h, :enter)

saved? =
  Enum.any?(1..50, fn _ ->
    Process.sleep(20)
    Enum.any?(Harlock.Test.model(h).contacts, &(&1.name == "Zed"))
  end)

unless saved? do
  IO.puts(:stderr, "FAIL: Enter in the dialog did not save the contact")
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
