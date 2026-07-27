defmodule Harlock.Sub.Telemetry do
  @moduledoc false
  # Lifetime owner for a `Sub.telemetry/2` subscription.
  #
  # `:telemetry` handlers are not processes. They are global entries in a table,
  # and nothing detaches them when the process that cared goes away — a handler
  # sending to a dead pid does not raise, so `:telemetry` never auto-detaches it
  # either. Left alone it leaks for the lifetime of the VM and accumulates on
  # every app restart.
  #
  # The runtime's subscription lifecycle is pid-shaped: `Sub.start/2` returns a
  # pid, and stopping means exiting it. So this module supplies a process whose
  # only job is to *be* the subscription's lifetime — it attaches on start and
  # detaches on the way out, and the runtime's existing diffing needs no
  # special case for handler-based sources.
  #
  # It traps exits deliberately. The runtime stops a sub with
  # `Process.exit(pid, :shutdown)`, which kills a non-trapping process outright
  # and would run no cleanup at all, leaking exactly the handler this process
  # exists to own.
  #
  # Events are *not* routed through here. The handler sends straight to the
  # runtime, because it executes inside whichever process emitted the event and
  # a hop through this process would put it on the hot path of the system being
  # measured.

  @spec start_link([[atom()]], function(), pid()) :: pid()
  def start_link(events, transform, target) do
    spawn_link(fn -> init(events, transform, target) end)
  end

  defp init(events, transform, target) do
    Process.flag(:trap_exit, true)
    id = handler_id(events, target)

    # A named function, not a closure: :telemetry warns about anonymous handlers
    # for real performance reasons. The transform rides in the config instead,
    # where being anonymous costs nothing.
    :ok =
      :telemetry.attach_many(
        id,
        events,
        &__MODULE__.handle/4,
        %{target: target, transform: transform}
      )

    wait(id)
  end

  defp wait(id) do
    receive do
      {:EXIT, _from, _reason} -> :telemetry.detach(id)
      _other -> wait(id)
    end
  end

  @doc false
  # Runs in the emitting process. Does the minimum: build a term, send it, return.
  def handle(event, measurements, metadata, %{target: target, transform: transform}) do
    message =
      cond do
        is_function(transform, 1) -> transform.(measurements)
        is_function(transform, 3) -> transform.(event, measurements, metadata)
        true -> {event, measurements, metadata}
      end

    send(target, {:harlock_event, message})
    :ok
  end

  # Unique per subscription *and* per runtime, so two apps watching the same
  # event do not collide on a handler id and silently unsubscribe each other.
  defp handler_id(events, target) do
    {__MODULE__, events, target}
  end
end
