Code.require_file("examples/sysmon.exs")

# Verify Sysmon boots under the Test backend, renders a non-empty frame
# containing the title bar, responds to ? (help overlay) and Esc, and
# responds to q (quit confirm) with y for confirm.

h = Harlock.Test.start_app(Sysmon, nil, rows: 20, cols: 100)

frame = Harlock.Test.render(h)

unless String.contains?(frame, "Sysmon") do
  IO.puts(:stderr, "FAIL: title not in initial render")
  IO.puts(frame)
  System.halt(1)
end

unless String.contains?(frame, "processes") do
  IO.puts(:stderr, "FAIL: status line not in initial render")
  IO.puts(frame)
  System.halt(1)
end

# Help overlay
Harlock.Test.send_key(h, {:char, ??})
frame = Harlock.Test.render(h)

unless String.contains?(frame, "Help") do
  IO.puts(:stderr, "FAIL: help overlay did not render")
  IO.puts(frame)
  System.halt(1)
end

# Close help
Harlock.Test.send_key(h, :escape)
frame = Harlock.Test.render(h)

unless String.contains?(frame, "Sysmon") and not String.contains?(frame, " Help") do
  IO.puts(:stderr, "FAIL: help overlay did not close")
  IO.puts(frame)
  System.halt(1)
end

# Move cursor
state_before = Harlock.Test.model(h)
Harlock.Test.send_key(h, :down)
state_after = Harlock.Test.model(h)

unless state_before.cursor != state_after.cursor do
  IO.puts(:stderr, "FAIL: cursor did not advance on Down")
  System.halt(1)
end

# Quit confirm + cancel
Harlock.Test.send_key(h, {:char, ?q})
frame = Harlock.Test.render(h)
unless String.contains?(frame, "Quit?") do
  IO.puts(:stderr, "FAIL: quit confirm did not appear")
  IO.puts(frame)
  System.halt(1)
end

Harlock.Test.send_key(h, {:char, ?n})
frame = Harlock.Test.render(h)
if String.contains?(frame, "Quit?") do
  IO.puts(:stderr, "FAIL: quit confirm did not close on n")
  System.halt(1)
end

# Quit confirm + y. Under the Test backend the app's update returns :quit,
# the runtime exits, but the supervisor stays alive until stop/1.
Harlock.Test.send_key(h, {:char, ?q})
Harlock.Test.send_key(h, {:char, ?y})

unless Harlock.Test.quit?(h) do
  IO.puts(:stderr, "FAIL: runtime did not exit after y")
  System.halt(1)
end

Harlock.Test.stop(h)

unless not Process.alive?(h.sup) do
  IO.puts(:stderr, "FAIL: supervisor still alive after stop")
  System.halt(1)
end

IO.puts("PASS")
System.halt(0)
