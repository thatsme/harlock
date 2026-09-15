defmodule Harlock.Examples.ContactsTest do
  use ExUnit.Case, async: true

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "contacts.exs"]))

  defp start,
    do: Harlock.Test.start_app(ContactsApp, nil, [rows: 24, cols: 80] ++ ContactsApp.run_opts())

  # 1-indexed {col, row} of the first occurrence of `needle` on screen, as a
  # terminal would report a click on it.
  defp position_of(h, needle) do
    h
    |> Harlock.Test.render()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, row} ->
      case :binary.match(line, needle) do
        {byte, _} -> {String.length(binary_part(line, 0, byte)) + 1, row}
        :nomatch -> nil
      end
    end) || flunk("#{inspect(needle)} is not on screen:\n#{Harlock.Test.render(h)}")
  end

  defp click(h, needle, offset \\ 0) do
    {col, row} = position_of(h, needle)
    Harlock.Test.send_mouse(h, :press, :left, col + offset, row)
  end

  # Saving goes through a Cmd with a delay, so its result arrives later.
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp contact(h, name), do: Enum.find(Harlock.Test.model(h).contacts, &(&1.name == name))

  test "favourites carry a star in the list, and details are shown for the selection" do
    h = start()
    screen = Harlock.Test.render(h)

    assert screen =~ "Alice Wong ★"
    assert screen =~ "Details — Alice Wong"
    assert screen =~ "★ Favourite"
    refute screen =~ "Bob Martin ★"
    Harlock.Test.stop(h)
  end

  test "the status line shows the focus the frame is drawn with" do
    h = start()
    assert Harlock.Test.render(h) =~ "focus: search"

    Harlock.Test.send_key(h, :tab)
    Harlock.Test.send_key(h, {:char, ?a})
    assert Harlock.Test.render(h) =~ "focus: dialog: name"
    Harlock.Test.stop(h)
  end

  test "clicking a row selects it, and Enter on the list opens it for editing" do
    h = start()
    click(h, "Bob Martin")

    assert Harlock.Test.focused(h) == :contact_list
    assert Harlock.Test.render(h) =~ "Details — Bob Martin"

    Harlock.Test.send_key(h, :enter)
    assert Harlock.Test.render(h) =~ "Edit Contact"
    assert Harlock.Test.model(h).modal.name == "Bob Martin"
    Harlock.Test.stop(h)
  end

  test "clicking a pane's border focuses its widget" do
    h = start()
    click(h, "Contacts (5)")
    assert Harlock.Test.focused(h) == :contact_list

    click(h, "╭ Search")
    assert Harlock.Test.focused(h) == :search
    Harlock.Test.stop(h)
  end

  test "the dialog hides the details behind it" do
    h = start()
    Harlock.Test.send_key(h, :tab)
    Harlock.Test.send_key(h, {:char, ?a})

    # The details pane's labels sit under the dialog's blank rows.
    refute Harlock.Test.render(h) =~ "alice@example.com"
    Harlock.Test.stop(h)
  end

  test "Add, the favourite checkbox and Save, all by mouse" do
    h = start()
    click(h, "[ Add ]", 2)
    assert Harlock.Test.render(h) =~ "New Contact"

    for c <- ~c"Zed", do: Harlock.Test.send_key(h, {:char, c})
    click(h, "[ ] ★ Favourite", 1)
    assert Harlock.Test.model(h).modal.favourite

    click(h, "[ Save ]", 2)
    assert eventually(fn -> contact(h, "Zed") end)
    assert contact(h, "Zed").favourite
    assert Harlock.Test.render(h) =~ "Zed ★"
    Harlock.Test.stop(h)
  end

  test "Cancel closes the dialog without saving, and focus goes back" do
    h = start()
    Harlock.Test.send_key(h, :tab)
    Harlock.Test.send_key(h, {:char, ?e})
    Harlock.Test.send_key(h, {:char, ?!})

    click(h, "[ Cancel ]", 2)
    assert Harlock.Test.model(h).modal == nil
    assert Harlock.Test.focused(h) == :contact_list
    assert contact(h, "Alice Wong")
    Harlock.Test.stop(h)
  end

  test "a second submit while saving does not add the contact twice" do
    h = start()
    Harlock.Test.send_key(h, :tab)
    Harlock.Test.send_key(h, {:char, ?a})
    for c <- ~c"Zed", do: Harlock.Test.send_key(h, {:char, c})

    Harlock.Test.send_key(h, :enter)
    Harlock.Test.send_key(h, :enter)
    Harlock.Test.send_key(h, :escape)

    assert eventually(fn -> Harlock.Test.model(h).modal == nil end)
    assert Enum.count(Harlock.Test.model(h).contacts, &(&1.name == "Zed")) == 1
    Harlock.Test.stop(h)
  end

  test "the Delete button removes the selected contact" do
    h = start()
    click(h, "Charlie Kim")
    click(h, "[ Delete ]", 2)

    refute contact(h, "Charlie Kim")
    assert Harlock.Test.render(h) =~ "Contacts (4)"
    Harlock.Test.stop(h)
  end
end
