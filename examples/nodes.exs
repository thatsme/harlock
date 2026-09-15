# Run with:
#   ./scripts/run.sh nodes
#
# or directly:
#   mix run examples/nodes.exs --run
#
# Not from an IEx prompt: IEx's terminal driver reads the same tty, and the app
# would not receive keystrokes.
#
# A BEAM node explorer: process list, supervision trees, and memory over time.
# `observer` for people on SSH, and the first application built on Harlock rather
# than a demonstration of one widget.
#
# It exists to exercise the parts of the API that a 1.0 freeze would lock while
# they are still young:
#
#   * table's window function — the process list is thousands of rows on a busy
#     node. Pids are cheap to enumerate; Process.info is not, so only the visible
#     window gets hydrated. The wheel scrolls it; a click on a process shows its
#     details underneath.
#   * tree's lazy children — a supervision tree is exactly this shape. Expanding
#     a supervisor calls which_children through a Cmd rather than up front. A
#     click on a marker expands it.
#   * sparkline + Sub.interval — memory sampled on a timer.
#   * tabs — clickable, or 1 / 2 / 3 from anywhere.
#
# Everything here is standard OTP introspection. No dependencies.

defmodule Nodes do
  use Harlock.App

  alias Harlock.Tree

  @history 120
  @refresh 1_000

  @tabs [processes: "1 processes", supervisors: "2 supervisors", memory: "3 memory"]

  def init(_) do
    %{
      node: Node.self(),
      tab: :processes,
      # Listed at once rather than on the first sample, so the table is not
      # empty for a second after starting.
      pids: Process.list(),
      proc_offset: 0,
      selected: nil,
      roots: [],
      expanded: MapSet.new(),
      focused: nil,
      memory: [div(:erlang.memory(:total), 1024)],
      procs: :erlang.system_info(:process_count),
      status: nil
    }
  end

  def subs(_m), do: [Sub.interval(@refresh, :sample)]

  # -- sampling --------------------------------------------------------------

  def update(:sample, m) do
    {%{m | pids: Process.list(), procs: :erlang.system_info(:process_count)},
     Cmd.from(fn -> {:memory, :erlang.memory(:total)} end)}
  end

  def update({:memory, bytes}, m) do
    %{m | memory: Enum.take([div(bytes, 1024) | m.memory], @history)}
  end

  # -- tabs ------------------------------------------------------------------

  def update({:harlock_select, :tabs, tab}, m), do: switch(m, tab)

  def update({:key, {:char, c}, []}, m) when c in ?1..?3,
    do: switch(m, @tabs |> Enum.at(c - ?1) |> elem(0))

  # -- process list ----------------------------------------------------------
  #
  # The table owns no scroll state, so :offset lives here — the same arrangement
  # viewport has, and the same routed message. Six hand-written key clauses used
  # to sit here before `table` became auto-routed; this is what replaced them.
  #
  # A window function moves the offset, not a focused row, so the arrows scroll
  # and choosing a process is a click.

  def update({:harlock_scroll, :procs, offset}, m), do: %{m | proc_offset: offset}
  def update({:harlock_select, :procs, pid}, m), do: %{m | selected: pid}

  # -- supervision tree ------------------------------------------------------

  def update({:harlock_select, :sups, id}, m), do: %{m | focused: id}

  def update({:harlock_toggle, :sups, id}, m) do
    if MapSet.member?(m.expanded, id) do
      %{m | expanded: MapSet.delete(m.expanded, id)}
    else
      # Children are fetched off the render path. which_children/1 is a call into
      # the supervisor, so doing it inside view/1 would block rendering on
      # another process — and on a remote node, on the network.
      {%{m | expanded: MapSet.put(m.expanded, id), roots: mark(m.roots, id, :loading)},
       Cmd.from(fn -> {:children, id, children_of(id)} end)}
    end
  end

  def update({:children, id, children}, m), do: %{m | roots: mark(m.roots, id, children)}

  def update({:harlock_submit, :sups}, m), do: %{m | status: "leaf #{inspect(m.focused)}"}

  def update({:key, :escape, []}, _m), do: :quit
  def update(_event, m), do: m

  defp switch(m, :supervisors), do: load_roots(%{m | tab: :supervisors})
  defp switch(m, tab), do: %{m | tab: tab}

  defp load_roots(%{roots: []} = m) do
    roots = root_supervisors()
    %{m | roots: roots, focused: roots |> List.first() |> then(&(&1 && &1.id))}
  end

  defp load_roots(m), do: m

  # -- view ------------------------------------------------------------------

  def view(m) do
    vbox(
      constraints: [length: 1, length: 1, fill: 1, length: 1],
      children: [
        text(header(m)),
        tabs(focusable: :tabs, items: @tabs, active: m.tab, separator: "  "),
        body(m),
        keybar(
          bindings: [{"Tab", "focus"}, {"1-3", "tabs"}, {"wheel", "scroll"}, {"Esc", "quit"}],
          right: if(m.status, do: " #{m.status} ", else: "")
        )
      ]
    )
  end

  defp header(m) do
    [
      {" #{m.node} ", bold: true, reverse: true},
      "   procs ",
      {"#{m.procs}", bold: true},
      "   mem ",
      {"#{m.memory |> List.first(0) |> div(1024)} MB", bold: true, fg: :cyan}
    ]
  end

  defp body(%{tab: :processes} = m) do
    vbox(
      constraints: [fill: 1, length: 4],
      children: [
        box(
          title: "processes (#{length(m.pids)})",
          border: :rounded,
          focus_proxy: :procs,
          child:
            table(
              focusable: :procs,
              columns: [
                column(title: "pid", width: {:length, 14}, render: & &1.pid),
                column(title: "name / initial call", width: {:fill, 2}, render: & &1.name),
                column(title: "reds", width: {:length, 12}, render: & &1.reductions),
                column(title: "mem", width: {:length, 10}, render: & &1.memory),
                column(title: "msgq", width: {:length, 6}, render: & &1.queue)
              ],
              row_id: & &1.raw,
              offset: m.proc_offset,
              focused_row: m.selected,
              # The point of the window function: enumerating pids is one cheap
              # list, but Process.info on every one of them is not. Only the rows
              # about to be drawn get hydrated.
              rows: fn offset, limit -> hydrate(m.pids, offset, limit) end
            )
        ),
        box(
          title: "selected",
          border: :rounded,
          padding: {0, 1},
          child: text(details(m.selected))
        )
      ]
    )
  end

  defp body(%{tab: :supervisors} = m) do
    box(
      title: "supervision tree",
      border: :rounded,
      focus_proxy: :sups,
      child:
        tree(
          focusable: :sups,
          nodes: m.roots,
          expanded: m.expanded,
          focused: m.focused
        )
    )
  end

  defp body(%{tab: :memory} = m) do
    vbox(
      constraints: [length: 3, fill: 1],
      children: [
        box(
          title: "total memory (KB)",
          border: :rounded,
          child: sparkline(values: Enum.reverse(m.memory), style: [fg: :cyan])
        ),
        box(
          title: "system",
          border: :rounded,
          padding: {0, 1},
          child: text(system_lines())
        )
      ]
    )
  end

  # -- data ------------------------------------------------------------------

  # Called from view/1, so it must stay cheap: `limit` rows of Process.info and
  # nothing else. A remote node would need this fetched into the model by a Cmd
  # instead — the window function runs inside rendering, and blocking a render on
  # the network is not acceptable.
  defp hydrate(pids, offset, limit) do
    pids
    |> Enum.slice(offset, limit)
    |> Enum.map(&row_for/1)
    |> Enum.reject(&is_nil/1)
  end

  defp row_for(pid) do
    case Process.info(pid, [
           :registered_name,
           :initial_call,
           :reductions,
           :memory,
           :message_queue_len
         ]) do
      nil ->
        nil

      info ->
        %{
          raw: pid,
          pid: inspect(pid),
          name: describe(info[:registered_name], info[:initial_call]),
          reductions: to_string(info[:reductions]),
          memory: to_string(info[:memory]),
          queue: to_string(info[:message_queue_len])
        }
    end
  end

  # One process's worth of Process.info, for the selected one only.
  defp details(nil), do: [{"click a process to see it here", dim: true}]

  defp details(pid) do
    case Process.info(pid, [:status, :current_function, :links, :message_queue_len, :memory]) do
      nil ->
        [{inspect(pid), bold: true}, {"  has exited", fg: :red}]

      info ->
        {mod, fun, arity} = info[:current_function]
        queue = info[:message_queue_len]

        [
          {inspect(pid), bold: true},
          label("status"),
          {"#{info[:status]}", fg: :green},
          label("in"),
          "#{inspect(mod)}.#{fun}/#{arity}",
          "\n",
          label("links", false),
          "#{length(info[:links])}",
          label("msgq"),
          {"#{queue}", fg: if(queue > 0, do: :yellow, else: :default)},
          label("mem"),
          "#{info[:memory]} B"
        ]
    end
  end

  defp label(name, gap \\ true), do: {if(gap, do: "   #{name} ", else: "#{name} "), fg: :cyan}

  defp describe([], {m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp describe(name, _initial) when is_atom(name), do: to_string(name)
  defp describe(_, _), do: "?"

  # A supervisor announces itself in its process dictionary; there is no registry
  # of them to consult.
  #
  # A *root* is one whose parent is not itself a supervisor. Listing every
  # supervisor instead shows `logger_sup` and `kernel_safe_sup` twice — once at
  # the top level and again under `kernel_sup` — which is how this first read
  # before the tree was looked at.
  defp root_supervisors do
    for pid <- Process.list(), supervisor?(pid), not child_of_supervisor?(pid) do
      %{id: pid, label: label_for(pid), children: :unloaded}
    end
  end

  defp child_of_supervisor?(pid) do
    case Process.info(pid, :parent) do
      {:parent, parent} when is_pid(parent) -> supervisor?(parent)
      _ -> false
    end
  end

  defp supervisor?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> match?({:supervisor, _, _}, dict[:"$initial_call"])
      _ -> false
    end
  end

  defp label_for(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> "#{name}"
      _ -> inspect(pid)
    end
  end

  defp children_of(pid) do
    for {id, child, type, _mods} <- :supervisor.which_children(pid), is_pid(child) do
      %{
        id: child,
        label: "#{inspect(id)} #{inspect(child)}",
        children: if(type == :supervisor, do: :unloaded, else: [])
      }
    end
  rescue
    # A supervisor that died between listing and asking is normal on a live node.
    _ -> []
  end

  # Walks the loaded parts of the tree only; an :unloaded branch cannot contain
  # the id being marked, because it has no children yet.
  defp mark(nodes, id, children) do
    Enum.map(nodes, fn
      %{id: ^id} = node ->
        %{node | children: children}

      node ->
        case Tree.children(node) do
          list when is_list(list) -> %{node | children: mark(list, id, children)}
          _lazy -> node
        end
    end)
  end

  defp system_lines do
    [
      {"process_count  ", fg: :cyan},
      "#{:erlang.system_info(:process_count)} / #{:erlang.system_info(:process_limit)}\n",
      {"atom_count     ", fg: :cyan},
      "#{:erlang.system_info(:atom_count)} / #{:erlang.system_info(:atom_limit)}\n",
      {"ets_count      ", fg: :cyan},
      "#{length(:ets.all())}\n",
      {"schedulers     ", fg: :cyan},
      "#{:erlang.system_info(:schedulers_online)}\n",
      {"run_queue      ", fg: :cyan},
      "#{:erlang.statistics(:run_queue)}\n",
      {"uptime         ", fg: :cyan},
      "#{:erlang.statistics(:wall_clock) |> elem(0) |> div(1000)}s"
    ]
  end

  @doc false
  # The options `--run` starts the app with. The tests start it with these too,
  # so a test cannot pass on an option the real app never sets.
  def run_opts, do: [mouse: true]
end

# `--run` starts the app; without it the file only defines the module, which is
# how the tests load it.
case System.argv() do
  ["--run"] -> Harlock.run(Nodes, nil, Nodes.run_opts())
  _ -> :ok
end
