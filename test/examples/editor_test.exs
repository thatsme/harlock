defmodule Harlock.Examples.EditorTest do
  # async: false — the editor command comes from $VISUAL / $EDITOR, which these
  # tests set and restore.
  use ExUnit.Case, async: false

  Code.require_file(Path.join([__DIR__, "..", "..", "examples", "editor.exs"]))

  setup do
    dir =
      Path.join(System.tmp_dir!(), "harlock_editor_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "alpha\nsecond line\n")
    File.write!(Path.join(dir, "b.txt"), "bravo\n")
    File.write!(Path.join(dir, "long.txt"), Enum.map_join(1..60, "\n", &"line #{&1}"))

    saved = for var <- ~w(VISUAL EDITOR), do: {var, System.get_env(var)}

    on_exit(fn ->
      File.rm_rf!(dir)

      for {var, value} <- saved,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)

    {:ok, dir: dir}
  end

  defp start(dir, opts \\ []) do
    Harlock.Test.start_app(Editor, dir, [rows: 20, cols: 90, mouse: true] ++ opts)
  end

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
    end)
  end

  # Cmd.exec and Cmd.suspend results arrive as messages after the keypress that
  # dispatched them, so a check on their outcome waits for it.
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

  defp status(h),
    do:
      h
      |> Harlock.Test.model()
      |> Map.fetch!(:status)
      |> List.wrap()
      |> Enum.map_join(fn
        {t, _} -> t
        t -> t
      end)

  test "lists the files and previews the first", %{dir: dir} do
    h = start(dir)
    screen = Harlock.Test.render(h)

    assert screen =~ "a.txt"
    assert screen =~ "b.txt"
    assert screen =~ "Preview — a.txt"
    assert screen =~ "second line"
    Harlock.Test.stop(h)
  end

  test "moving through the list previews each file", %{dir: dir} do
    h = start(dir)
    Harlock.Test.send_key(h, :down)

    assert Harlock.Test.render(h) =~ "Preview — b.txt"
    assert Harlock.Test.render(h) =~ "bravo"
    Harlock.Test.stop(h)
  end

  test "Enter opens $VISUAL with its arguments, and the preview reloads after", %{dir: dir} do
    System.put_env("VISUAL", "myeditor --wait")
    System.put_env("EDITOR", "ignored")
    test_pid = self()

    exec = fn program, args, _opts ->
      send(test_pid, {:exec, program, args})
      File.write!(List.last(args), "bravo, edited\n")
      {:ok, 0}
    end

    h = start(dir, exec: exec)
    Harlock.Test.send_key(h, :down)
    Harlock.Test.send_key(h, :enter)

    path = Path.join(Path.expand(dir), "b.txt")
    assert_receive {:exec, "myeditor", ["--wait", ^path]}
    assert eventually(fn -> Harlock.Test.render(h) =~ "bravo, edited" end)
    assert status(h) =~ "b.txt reloaded"
    Harlock.Test.stop(h)
  end

  test "without $VISUAL or $EDITOR it runs vi", %{dir: dir} do
    System.delete_env("VISUAL")
    System.delete_env("EDITOR")
    test_pid = self()

    h =
      start(dir,
        exec: fn program, _args, _opts -> send(test_pid, {:exec, program}) && {:ok, 0} end
      )

    Harlock.Test.send_key(h, :enter)

    assert_receive {:exec, "vi"}
    Harlock.Test.stop(h)
  end

  test "an editor that cannot be found says so", %{dir: dir} do
    System.put_env("VISUAL", "no-such-editor")

    h = start(dir, exec: fn _, _, _ -> {:error, {:exec, :enoent}} end)
    Harlock.Test.send_key(h, :enter)

    assert eventually(fn -> status(h) =~ "Could not find no-such-editor" end)
    Harlock.Test.stop(h)
  end

  test "Ctrl-Z suspends, and the app says it is back", %{dir: dir} do
    h = start(dir, suspend: fn -> {:ok, :resumed} end)
    Harlock.Test.send_key(h, {:char, ?z}, [:ctrl])

    assert eventually(fn -> status(h) =~ "Back from the shell" end)
    Harlock.Test.stop(h)
  end

  test "clicking a file previews it, and clicking the button opens it", %{dir: dir} do
    test_pid = self()

    h =
      start(dir,
        exec: fn _, args, _ ->
          send(test_pid, {:opened, Path.basename(List.last(args))}) && {:ok, 0}
        end
      )

    {col, row} = position_of(h, "b.txt")
    Harlock.Test.send_mouse(h, :press, :left, col, row)
    assert Harlock.Test.render(h) =~ "Preview — b.txt"

    {col, row} = position_of(h, "[ Open in editor ]")
    Harlock.Test.send_mouse(h, :press, :left, col + 2, row)
    assert_receive {:opened, "b.txt"}
    Harlock.Test.stop(h)
  end

  test "the wheel scrolls the preview", %{dir: dir} do
    h = start(dir)
    {col, row} = position_of(h, "long.txt")
    Harlock.Test.send_mouse(h, :press, :left, col, row)

    {col, row} = position_of(h, "line 1")
    Harlock.Test.send_mouse(h, :wheel_down, nil, col, row)

    assert Harlock.Test.model(h).preview_offset == 3
    refute Harlock.Test.render(h) =~ "line 1\n"
    Harlock.Test.stop(h)
  end
end
