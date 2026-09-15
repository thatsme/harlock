# Run with:
#   ./scripts/run.sh editor
#
# or directly, on a directory of your own:
#   mix run examples/editor.exs --run [directory]
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes. Without a directory it works on a scratch
# directory of sample files, so nothing of yours is edited by accident.
#
# A file browser that hands the terminal to your editor and takes it back:
#
#   * Cmd.exec     — Enter, or the "Open in editor" button, runs $VISUAL, then
#                    $EDITOR, then vi, on the selected file. The app redraws and
#                    reloads the preview when the editor exits.
#   * Cmd.suspend  — Ctrl-Z drops to the shell; `fg` comes back.
#   * mouse        — click a file to preview it, click the button, scroll the
#                    preview with the wheel.
#   * styled text  — the header and the status line mix styles in one line.
#
# Tab cycles focus between the file list, the button and the preview.

defmodule Editor do
  use Harlock.App

  alias Harlock.Cmd
  alias Harlock.Focus

  # A preview is for looking, not loading: large files show their head.
  @preview_limit 64_000

  def init(dir) do
    dir = Path.expand(dir)
    files = list_files(dir)
    selected = files |> List.first() |> then(&(&1 && &1.name))

    %{
      dir: dir,
      files: files,
      selected: selected,
      preview: load_preview(dir, selected),
      preview_offset: 0,
      status: [
        "Enter or click ",
        {"Open in editor", bold: true},
        " to edit with ",
        {editor_label(), fg: :cyan}
      ]
    }
  end

  # -- selecting and scrolling ------------------------------------------------

  def update({:harlock_select, :files, name}, m), do: select(m, name)
  def update({:harlock_scroll, :preview, offset}, m), do: %{m | preview_offset: offset}

  # -- opening the editor -----------------------------------------------------

  # A table routes the arrows but not Enter, so Enter on the list is a raw key.
  def update({:key, :enter, []}, m) do
    if Focus.current() == :files, do: open(m), else: m
  end

  def update({:harlock_submit, :open}, m), do: open(m)

  def update({:edited, name, result}, m) do
    m = refresh(m)

    status =
      case result do
        {:ok, 0} ->
          [{"✓ ", fg: :green}, "Back from the editor — ", {name, bold: true}, " reloaded"]

        {:ok, code} ->
          [{"! ", fg: :yellow}, "The editor exited with status #{code}"]

        {:error, {:exec, :enoent}} ->
          [
            {"✗ ", fg: :red},
            "Could not find ",
            {editor_label(), bold: true},
            " — set $VISUAL or $EDITOR"
          ]

        {:error, {:signal, signal}} ->
          [{"! ", fg: :yellow}, "The editor was stopped by signal #{signal}"]

        {:error, reason} ->
          [{"✗ ", fg: :red}, "Could not run the editor: #{inspect(reason)}"]
      end

    %{m | status: status}
  end

  # -- the shell --------------------------------------------------------------

  def update({:key, {:char, ?z}, [:ctrl]}, m),
    do: {m, Cmd.suspend() |> Cmd.map(&{:suspended, &1})}

  def update({:suspended, {:ok, :resumed}}, m),
    do: %{refresh(m) | status: [{"✓ ", fg: :green}, "Back from the shell"]}

  def update({:suspended, {:error, :no_job_control}}, m),
    do: %{m | status: [{"! ", fg: :yellow}, "No job-control shell to suspend to"]}

  def update({:suspended, {:error, reason}}, m),
    do: %{m | status: [{"✗ ", fg: :red}, "Could not suspend: #{inspect(reason)}"]}

  # -- the rest ---------------------------------------------------------------

  def update({:key, {:char, ?r}, []}, m), do: %{refresh(m) | status: "Refreshed"}
  def update({:key, {:char, ?q}, []}, _m), do: :quit
  def update(_, m), do: m

  def view(m) do
    vbox(
      constraints: [length: 1, fill: 1, length: 1, length: 1],
      children: [
        text([{" Editor ", bold: true, reverse: true}, " ", {m.dir, fg: :cyan}]),
        hbox(
          constraints: [length: 34, fill: 1],
          children: [files_pane(m), preview_pane(m)]
        ),
        text([" " | List.wrap(m.status)]),
        keybar(
          bindings: [
            {"Tab", "focus"},
            {"Enter", "open"},
            {"r", "refresh"},
            {"Ctrl-Z", "suspend"},
            {"q", "quit"}
          ]
        )
      ]
    )
  end

  defp files_pane(m) do
    box(
      title: "Files (#{length(m.files)})",
      border: :rounded,
      focus_proxy: :files,
      child:
        vbox(
          constraints: [fill: 1, length: 1],
          children: [
            table(
              focusable: :files,
              columns: [
                column(width: {:fill, 1}, render: & &1.name),
                column(width: {:length, 8}, align: :right, render: &human_size(&1.size))
              ],
              rows: m.files,
              row_id: & &1.name,
              focused_row: m.selected,
              show_header: false
            ),
            button("Open in editor", focusable: :open)
          ]
        )
    )
  end

  # The preview shows lines as they are, without wrapping. Wrapping would need
  # the pane's width to size the viewport (Harlock.Text.height/2), and an app is
  # not told the terminal's size.
  defp preview_pane(m) do
    lines = String.split(m.preview, "\n")

    box(
      title: if(m.selected, do: "Preview — #{m.selected}", else: "Preview"),
      border: :rounded,
      focus_proxy: :preview,
      child:
        viewport(
          focusable: :preview,
          offset: m.preview_offset,
          content_height: length(lines),
          scrollbar: true,
          child: text(m.preview)
        )
    )
  end

  # -- helpers ----------------------------------------------------------------

  defp select(m, name),
    do: %{m | selected: name, preview: load_preview(m.dir, name), preview_offset: 0}

  defp refresh(m) do
    files = list_files(m.dir)

    selected =
      if Enum.any?(files, &(&1.name == m.selected)),
        do: m.selected,
        else: files |> List.first() |> then(&(&1 && &1.name))

    %{m | files: files, selected: selected, preview: load_preview(m.dir, selected)}
  end

  defp open(%{selected: nil} = m), do: %{m | status: "No file selected"}

  defp open(m) do
    [program | args] = editor_command()
    path = Path.join(m.dir, m.selected)

    {%{m | status: ["Opening ", {m.selected, bold: true}, " in ", {program, fg: :cyan}, "…"]},
     Cmd.exec(program, args ++ [path]) |> Cmd.map(&{:edited, m.selected, &1})}
  end

  @doc false
  # The options `--run` starts the app with. The tests start it with these too,
  # so a test cannot pass on an option the real app never sets.
  def run_opts, do: [mouse: true]

  @doc false
  # $VISUAL, then $EDITOR, then vi — read when the file is opened, so a change
  # in the environment applies without restarting. A value can carry arguments
  # ("code --wait"), which are split the way a shell would.
  def editor_command do
    case Enum.find([System.get_env("VISUAL"), System.get_env("EDITOR")], &(&1 not in [nil, ""])) do
      nil -> ["vi"]
      command -> OptionParser.split(command)
    end
  end

  defp editor_label, do: editor_command() |> hd()

  defp list_files(dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path -> %{name: Path.basename(path), size: File.stat!(path).size} end)
  end

  defp load_preview(_dir, nil), do: "(no files here)"

  defp load_preview(dir, name) do
    path = Path.join(dir, name)

    case File.open(path, [:read, :binary], &IO.binread(&1, @preview_limit)) do
      {:ok, data} when is_binary(data) ->
        cond do
          not String.valid?(data) -> "(binary file, #{human_size(File.stat!(path).size)})"
          byte_size(data) == @preview_limit -> data <> "\n… (preview truncated)"
          true -> data
        end

      {:ok, :eof} ->
        "(empty file)"

      {:error, reason} ->
        "(cannot read: #{inspect(reason)})"
    end
  end

  defp human_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human_size(bytes) when bytes < 1024 * 1024, do: "#{div(bytes, 1024)} KB"
  defp human_size(bytes), do: "#{div(bytes, 1024 * 1024)} MB"

  @doc false
  # A scratch directory of sample files, created once, for when no directory
  # is given.
  def demo_dir do
    dir = Path.join(System.tmp_dir!(), "harlock_editor_demo")
    File.mkdir_p!(dir)

    samples = %{
      "notes.md" =>
        "# Notes\n\nOpen this file with Enter, change something, save and quit.\nThe preview reloads when the editor exits.\n",
      "todo.txt" =>
        "- try Ctrl-Z, then `fg`\n- scroll this preview with the mouse wheel\n- click another file on the left\n",
      "hello.exs" => ~s|IO.puts("hello from the editor example")\n|
    }

    for {name, content} <- samples,
        not File.exists?(Path.join(dir, name)),
        do: File.write!(Path.join(dir, name), content)

    dir
  end
end

# `--run` starts the app; without it the file only defines the module, which is
# how the tests load it.
case System.argv() do
  ["--run"] -> Harlock.run(Editor, Editor.demo_dir(), Editor.run_opts())
  ["--run", dir] -> Harlock.run(Editor, dir, Editor.run_opts())
  _ -> :ok
end
