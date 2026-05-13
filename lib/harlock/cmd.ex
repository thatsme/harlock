defmodule Harlock.Cmd do
  @moduledoc """
  Side-effect descriptors returned from `init/1` and `update/2`.

  An app's `update/2` can return `{new_model, cmd}` to request side-effects.
  The runtime dispatches the cmd to a `Task.Supervisor` and re-enters the
  TEA loop; results arrive later as ordinary `{:harlock_event, result}`
  messages that `update/2` handles like any other event.

      def update(:fetch, model) do
        cmd = Cmd.from(fn -> HTTPoison.get!("https://example.com") end)
        {model, cmd}
      end

      def update({:ok, %{body: body}}, model), do: {%{model | body: body}, Cmd.none()}

  Constructors:

    * `none/0` — no side-effect. Equivalent to returning just the model.
    * `from/1` — run a 0-arity function in a task; deliver its return value.
    * `batch/1` — dispatch a list of cmds concurrently; no ordering guarantee.
    * `map/2` — tag/transform the result of an inner cmd before delivery.

  Task lifecycle: cmd tasks are supervised by `Harlock.App.TaskSupervisor`,
  itself a child of the app's supervisor positioned after `Runtime`. A
  Runtime exit terminates the task supervisor and all in-flight tasks
  (rest_for_one). A task crash is caught at the task body and delivered
  as `{:cmd_error, reason}`; it never propagates to the runtime.
  """

  require Logger

  @typedoc "An opaque cmd descriptor. Build one via the constructors."
  @opaque t ::
            :none
            | {:fun, (-> any())}
            | {:batch, [t()]}
            | {:map, t(), (any() -> any())}

  @spec none() :: t()
  def none, do: :none

  @spec from((-> any())) :: t()
  def from(fun) when is_function(fun, 0), do: {:fun, fun}

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
