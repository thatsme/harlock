defmodule Harlock.App.Supervisor do
  @moduledoc false
  # Top-level supervision tree for a running Harlock app.
  #
  # Children (rest_for_one):
  #
  #   1. Terminal.Keeper      owns /dev/tty + termios + SIGWINCH
  #   2. Terminal.Writer      ANSI output, fetches tty from Keeper
  #   3. Terminal.Reader      byte input + parsing, fetches tty from Keeper
  #   4. App.TaskSupervisor   supervises cmd tasks
  #   5. App.Runtime          the TEA loop
  #
  # rest_for_one means a Keeper crash takes down the whole tree (correct —
  # without a tty we have nothing to do); a Reader crash leaves Keeper +
  # Writer alive long enough to restore the terminal during shutdown.
  # TaskSupervisor sits BEFORE Runtime so it's available when Runtime
  # dispatches its init-time cmd; a TaskSupervisor crash terminates
  # Runtime (clean shutdown) but leaves IO alive long enough to restore.
  #
  # The Keeper is the load-bearing process for "terminal restored on crash":
  # its terminate/2 fires even when the entire app dies, because the
  # supervisor terminates children in reverse order, and Keeper is the
  # first (= last to die) child.

  use Supervisor

  alias Harlock.Terminal.Caps
  alias Harlock.Terminal.Keeper
  alias Harlock.Terminal.Reader
  alias Harlock.Terminal.Writer

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    backend = Keyword.get(opts, :backend, :terminal)
    keeper_name = :"#{name}.Keeper"
    writer_name = :"#{name}.Writer"
    reader_name = :"#{name}.Reader"
    runtime_name = :"#{name}.Runtime"
    task_sup_name = :"#{name}.TaskSupervisor"

    caps = Caps.detect()

    io_children =
      case backend do
        :terminal ->
          [
            %{
              id: :keeper,
              start: {Keeper, :start_link, [[name: keeper_name, runtime: runtime_name]]},
              shutdown: 5_000
            },
            %{
              id: :writer,
              start: {Writer, :start_link, [[caps: caps, name: writer_name]]},
              shutdown: 1_000
            },
            %{
              id: :reader,
              start: {Reader, :start_link, [[caps: caps, name: reader_name]]},
              shutdown: 1_000
            }
          ]

        :test ->
          rows = Keyword.get(opts, :rows, 24)
          cols = Keyword.get(opts, :cols, 80)

          [
            %{
              id: :writer,
              start:
                {Harlock.IO.Test.Writer, :start_link,
                 [[name: writer_name, rows: rows, cols: cols]]},
              shutdown: 1_000
            },
            %{
              id: :reader,
              start: {Harlock.IO.Test.Reader, :start_link, [[name: reader_name]]},
              shutdown: 1_000
            }
          ]
      end

    runtime_child = %{
      id: :runtime,
      start:
        {Harlock.App.Runtime, :start_link,
         [
           [
             app: Keyword.fetch!(opts, :app),
             init_arg: Keyword.get(opts, :init_arg),
             caller: Keyword.get(opts, :caller),
             writer: writer_name,
             reader: reader_name,
             task_sup: task_sup_name,
             name: runtime_name,
             rows: Keyword.get(opts, :rows),
             cols: Keyword.get(opts, :cols),
             theme: Keyword.get(opts, :theme, Harlock.Theme.default())
           ]
         ]},
      restart: :temporary,
      shutdown: 1_000
    }

    # TaskSupervisor sits BEFORE Runtime so it's already up when Runtime's
    # handle_continue tries to dispatch an init-time cmd. A TaskSupervisor
    # crash terminates Runtime (rest_for_one) — Runtime is :temporary so it
    # stays dead, IO survives long enough for the supervisor's terminate
    # cascade to restore the terminal.
    task_sup_child = %{
      id: :task_sup,
      start: {Task.Supervisor, :start_link, [[name: task_sup_name]]},
      type: :supervisor,
      restart: :temporary,
      shutdown: 5_000
    }

    # max_restarts: 0 means any child crash takes down the whole supervisor,
    # which in turn triggers Keeper.terminate/2 and restores the terminal.
    Supervisor.init(io_children ++ [task_sup_child, runtime_child],
      strategy: :rest_for_one,
      max_restarts: 0,
      max_seconds: 1
    )
  end
end
