# Run with:
#   ./scripts/run.sh nodes
#
# Or from iex:
#   iex -S mix
#   iex> c "examples/nodes.exs"
#   iex> Harlock.run(Nodes)
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
#     window gets hydrated.
#   * tree's lazy children — a supervision tree is exactly this shape. Expanding
#     a supervisor calls which_children through a Cmd rather than up front.
#   * sparkline + Sub.interval — memory sampled on a timer.
#
# Everything here is standard OTP introspection. No dependencies.

defmodule Nodes do
  use Harlock.App

  alias Harlock.Tree

  @history 120
  @refresh 1_000

  def init(_) do
    %{
      node: Node.self(),
      tab: :processes,
      pids: [],
      proc_offset: 0,
      roots: [],
      expanded: MapSet.new(),
      focused: nil,
      memory: [],
      procs: 0,
      status: "1 processes  2 supervisors  3 memory"
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

  def update({:key, {:char, ?1}, []}, m), do: %{m | tab: :processes}
  def update({:key, {:char, ?2}, []}, m), do: load_roots(%{m | tab: :supervisors})
  def update({:key, {:char, ?3}, []}, m), do: %{m | tab: :memory}

  # -- process list ----------------------------------------------------------
  #
  # The table owns no scroll state, so :offset lives here — the same arrangement
  # viewport has, and the same routed message. Six hand-written key clauses used
  # to sit here before `table` became auto-routed; this is what replaced them.

  def update({:harlock_scroll, :procs, offset}, m), do: %{m | proc_offset: offset}

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

  def update({:harlock_submit, :sups}, m), do: %{m | status: "leaf: #{inspect(m.focused)}"}

  def update({:key, :escape, []}, _m), do: :quit
  def update(_event, m), do: m

  defp load_roots(%{roots: []} = m) do
    roots = root_supervisors()
    %{m | roots: roots, focused: roots |> List.first() |> then(&(&1 && &1.id))}
  end

  defp load_roots(m), do: m

  # -- view ------------------------------------------------------------------

  def view(m) do
    vbox(
      constraints: [length: 1, fill: 1, length: 1],
      children: [
        text(header(m), style: [reverse: true]),
        body(m),
        text(m.status, style: [dim: true])
      ]
    )
  end

  defp header(m) do
    "#{m.node}   procs #{m.procs}   " <>
      "mem #{m.memory |> List.first(0) |> div(1024)}MB   " <>
      "[#{tab_label(m.tab)}]"
  end

  defp tab_label(:processes), do: "processes"
  defp tab_label(:supervisors), do: "supervisors"
  defp tab_label(:memory), do: "memory"

  defp body(%{tab: :processes} = m) do
    box(
      title: "processes (#{length(m.pids)})",
      border: :rounded,
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
          row_id: & &1.pid,
          offset: m.proc_offset,
          # The point of the window function: enumerating pids is one cheap list,
          # but Process.info on every one of them is not. Only the rows about to
          # be drawn get hydrated.
          rows: fn offset, limit -> hydrate(m.pids, offset, limit) end
        )
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
          child:
            vbox(
              constraints: List.duplicate({:length, 1}, 6),
              children: Enum.map(system_lines(), &text/1)
            )
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
    case Process.info(pid, [:registered_name, :initial_call, :reductions, :memory, :message_queue_len]) do
      nil ->
        nil

      info ->
        %{
          pid: inspect(pid),
          name: describe(info[:registered_name], info[:initial_call]),
          reductions: to_string(info[:reductions]),
          memory: to_string(info[:memory]),
          queue: to_string(info[:message_queue_len])
        }
    end
  end

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
      "process_count   #{:erlang.system_info(:process_count)} / #{:erlang.system_info(:process_limit)}",
      "atom_count      #{:erlang.system_info(:atom_count)} / #{:erlang.system_info(:atom_limit)}",
      "ets_count       #{length(:ets.all())}",
      "schedulers      #{:erlang.system_info(:schedulers_online)}",
      "run_queue       #{:erlang.statistics(:run_queue)}",
      "uptime          #{:erlang.statistics(:wall_clock) |> elem(0) |> div(1000)}s"
    ]
  end
end

# If running via `mix run examples/nodes.exs` (rather than loading via iex),
# kick off the app immediately.
case System.argv() do
  ["--run"] -> Harlock.run(Nodes)
  _ -> :ok
end
