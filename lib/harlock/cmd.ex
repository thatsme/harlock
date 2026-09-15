defmodule Harlock.Cmd do
  @moduledoc """
  Side-effect descriptors returned from `init/1` and `update/2`.

  An app's `update/2` can return `{new_model, cmd}` to request side-effects.
  The runtime dispatches the cmd to a `Task.Supervisor` and re-enters the
  TEA loop; the result arrives later as a message to `update/2`, handled like
  any other event. `map/2` tags it so the clause that receives it is easy to
  write:

      def update(:fetch, model) do
        cmd =
          Cmd.from(fn -> File.read("notes.txt") end)
          |> Cmd.map(&{:loaded, &1})

        {model, cmd}
      end

      def update({:loaded, {:ok, body}}, model), do: %{model | body: body}
      def update({:loaded, {:error, reason}}, model), do: %{model | error: reason}

  Constructors:

    * `none/0` — no side-effect. Equivalent to returning just the model.
    * `from/1` — run a 0-arity function in a task; deliver its return value.
    * `exec/3` — hand the terminal to another program until it exits.
    * `suspend/0` — stop the app for the shell's job control, as Ctrl-Z does.
    * `batch/1` — dispatch a list of cmds concurrently; no ordering guarantee.
    * `map/2` — tag/transform the result of an inner cmd before delivery.

  ## Running another program

  `exec/3` suspends the app's use of the terminal, runs a program with it, and
  resumes when the program exits — how an editor, pager, or `git commit` is run
  from a terminal UI:

      def update({:harlock_submit, :edit}, m) do
        {m, Cmd.exec("vim", [m.path]) |> Cmd.map(&{:edited, &1})}
      end

      def update({:edited, {:ok, 0}}, m), do: reload(m)
      def update({:edited, _failed}, m), do: %{m | status: "editor failed"}

  While the program runs it owns the terminal completely: the app's alternate
  screen is left, the terminal settings the shell had before the app started
  are restored, and keystrokes, Ctrl-C and window resizes go to the program.
  The app keeps running — subscriptions and other cmd results still reach
  `update/2` — but nothing is drawn. On exit the app redraws at the current
  size and receives the result:

    * `{:ok, exit_status}` — the program exited, with any status.
    * `{:error, {:signal, n}}` — it was killed by signal `n` (2 for Ctrl-C).
    * `{:error, {:exec, reason}}` — it could not be started, e.g. `:enoent`
      when `program` is not on `PATH`.
    * `{:error, {:chdir, reason}}` — the `:cd` directory could not be entered.
    * `{:error, :killed}` — the program was killed with the app, which ended
      while it ran.
    * `{:error, :busy}` — another program is already running.
    * `{:error, :not_foreground}` — the app does not hold the terminal's
      foreground, so it cannot hand it over.
    * other `{:error, {stage, reason}}` pairs for failures setting the program
      up (opening the terminal, a pipe, starting it), which are rare.
    * `{:error, :no_terminal}` — the app is not attached to a terminal, as under
      the test backend without an `:exec` stub (see `Harlock.Test.start_app/3`).

  Ctrl-Z inside the program works as it would at a shell prompt. When the
  program stops, the app stops with it, so the shell shows the job suspended;
  `fg` resumes the app, which gives the terminal back to the program and
  resumes it. That needs a job-control shell above
  the app — the same condition as `suspend/0` — and without one the program is
  resumed straight away, so Ctrl-Z does nothing rather than leaving it stuck.

  `exec/3` needs the app to own its terminal: run it with `mix run`, not from an
  IEx prompt, whose own terminal driver competes for input.

  ## Suspending

  In raw mode Ctrl-Z is an ordinary key, `{:key, {:char, ?z}, [:ctrl]}`, not a
  suspend: the terminal driver no longer turns it into a signal. An app that
  wants the usual job-control behaviour — Ctrl-Z to the shell, `fg` to come
  back — binds it to `suspend/0`:

      def update({:key, {:char, ?z}, [:ctrl]}, m), do: {m, Cmd.suspend()}

  The terminal is handed back to the shell as for `exec/3`, the app stops, and
  after `fg` it redraws at the current size and receives `{:ok, :resumed}`.
  It is not bound by default because apps use Ctrl-Z for other things, undo
  among them.

  Suspending needs a shell with job control to resume the app. Without one —
  the app started by a script, by `exec`, or under `script(1)` — it returns
  `{:error, :no_job_control}` and leaves the terminal as it was, rather than
  stopping with nothing to resume it. Other results: `{:error, :busy}` while an
  `exec/3` program runs, `{:error, :no_terminal}` under the test backend
  without a `:suspend` stub, and `{:error, :not_stopped}` if the stop was
  requested but did not happen, in which case the app simply carries on.

  Task lifecycle: `from/1` tasks run under a task supervisor in the app's
  supervision tree, started before the runtime. They end with the app: quitting
  stops the tree, and so does a crash. A crash inside a task is caught at the
  task body and delivered as `{:cmd_error, reason}`; it never propagates to the
  runtime. `exec/3` and `suspend/0` are not tasks — the runtime carries them
  out itself.
  """

  require Logger

  @typedoc "An opaque cmd descriptor. Build one via the constructors."
  @opaque t ::
            :none
            | {:fun, (-> any())}
            | {:exec, String.t(), [String.t()], keyword()}
            | :suspend
            | {:batch, [t()]}
            | {:map, t(), (any() -> any())}

  @spec none() :: t()
  def none, do: :none

  @spec from((-> any())) :: t()
  def from(fun) when is_function(fun, 0), do: {:fun, fun}

  @doc """
  Run `program` with the terminal until it exits. See "Running another program"
  above.

  `program` is looked up on `PATH` unless it contains a `/`. `args` are passed
  as-is, with no shell in between — use `exec("sh", ["-c", script])` when a
  shell is wanted.

  Options:
    * `:cd` — directory to run the program in.
    * `:env` — environment variables to set for the program, as `{name, value}`
      pairs or a map, on top of the current environment. A `nil` value unsets
      the variable.
  """
  @spec exec(String.t(), [String.t()], keyword()) :: t()
  def exec(program, args \\ [], opts \\ []) do
    unless is_binary(program) and program != "" and not String.contains?(program, <<0>>),
      do:
        raise(ArgumentError, "exec/3 expects a non-empty program name, got: #{inspect(program)}")

    unless is_list(args) and Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, <<0>>))),
      do:
        raise(ArgumentError, "exec/3 expects args to be a list of strings, got: #{inspect(args)}")

    {:exec, program, args, validate_exec_opts!(opts)}
  end

  defp validate_exec_opts!(opts) when is_list(opts) do
    Enum.map(opts, fn
      {:cd, dir} when is_binary(dir) ->
        {:cd, dir}

      {:env, env} when is_map(env) or is_list(env) ->
        env =
          Enum.map(env, fn
            {k, v} when is_binary(k) and (is_binary(v) or is_nil(v)) ->
              {k, v}

            other ->
              raise ArgumentError,
                    "exec/3 :env entries must be {string, string | nil}, got: #{inspect(other)}"
          end)

        {:env, env}

      other ->
        raise ArgumentError, "exec/3 got an unknown or malformed option: #{inspect(other)}"
    end)
  end

  defp validate_exec_opts!(other),
    do: raise(ArgumentError, "exec/3 expects options as a keyword list, got: #{inspect(other)}")

  @doc """
  Stop the app for the shell's job control, as Ctrl-Z would. See "Suspending"
  above.
  """
  @spec suspend() :: t()
  def suspend, do: :suspend

  @spec batch([t()]) :: t()
  def batch(cmds) when is_list(cmds), do: {:batch, cmds}

  @spec map(t(), (any() -> any())) :: t()
  def map(cmd, fun) when is_function(fun, 1), do: {:map, cmd, fun}

  @doc false
  @spec dispatch(t(), pid(), atom() | pid()) :: :ok
  def dispatch(cmd, runtime, task_sup) do
    :telemetry.execute([:harlock, :cmd, :dispatch], %{count: 1}, %{kind: kind(cmd)})
    dispatch_with(cmd, runtime, task_sup, [])
  end

  defp kind(:none), do: :none
  defp kind({:fun, _}), do: :fun
  defp kind({:exec, _, _, _}), do: :exec
  defp kind(:suspend), do: :suspend
  defp kind({:batch, _}), do: :batch
  defp kind({:map, _, _}), do: :map

  defp dispatch_with(:none, _runtime, _sup, _mappers), do: :ok

  defp dispatch_with({:fun, fun}, runtime, sup, mappers) do
    {:ok, _pid} =
      Task.Supervisor.start_child(sup, fn ->
        start = System.monotonic_time()
        result = run_safely(fun)
        duration = System.monotonic_time() - start

        status = if match?({:cmd_error, _}, result), do: :error, else: :ok

        :telemetry.execute(
          [:harlock, :cmd, :complete],
          %{duration: duration},
          %{status: status}
        )

        tagged = apply_mappers(result, mappers)
        send(runtime, {:harlock_event, tagged})
      end)

    :ok
  end

  # Not a task: handing the terminal over needs the runtime, the Reader, the
  # Writer and the Keeper in sequence, so the runtime runs it.
  defp dispatch_with({:exec, program, args, opts}, runtime, _sup, mappers) do
    send(runtime, {:harlock_exec, program, args, opts, &apply_mappers(&1, mappers)})
    :ok
  end

  defp dispatch_with(:suspend, runtime, _sup, mappers) do
    send(runtime, {:harlock_suspend, &apply_mappers(&1, mappers)})
    :ok
  end

  defp dispatch_with({:batch, cmds}, runtime, sup, mappers) do
    Enum.each(cmds, &dispatch_with(&1, runtime, sup, mappers))
  end

  defp dispatch_with({:map, cmd, mapper}, runtime, sup, mappers) do
    dispatch_with(cmd, runtime, sup, [mapper | mappers])
  end

  defp run_safely(fun) do
    fun.()
  rescue
    e ->
      Logger.error("Harlock cmd crashed: #{Exception.format(:error, e, __STACKTRACE__)}")
      {:cmd_error, {:exception, e}}
  catch
    kind, reason ->
      Logger.error("Harlock cmd crashed (#{kind}): #{inspect(reason)}")
      {:cmd_error, {kind, reason}}
  end

  defp apply_mappers(result, []), do: result

  defp apply_mappers(result, mappers) do
    Enum.reduce(mappers, result, fn fun, acc -> fun.(acc) end)
  end
end
