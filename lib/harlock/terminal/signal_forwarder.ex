defmodule Harlock.Terminal.SignalForwarder do
  @moduledoc false
  # Delivers OS signals to a process as `{:signal, signal}` messages.
  #
  # `:os.set_signal(sig, :handle)` does not send anything to the process that
  # called it. OTP routes handled signals to the `erl_signal_server` event
  # manager, which passes them to its `:gen_event` handlers. A process that
  # wants the signal in its mailbox has to add a handler there, which is what
  # this module is.
  #
  # The event manager is global and already shared: OTP's own
  # `prim_tty_sighandler` sits on it and depends on `:sigwinch` being
  # handled. So `uninstall/2` removes this handler and leaves the signal's
  # disposition alone. Resetting it to `:default` would silently break the
  # shell's resize handling after the app exits, and costs nothing to skip:
  # SIGWINCH and SIGCONT are ignored by default anyway.
  #
  # The handler only sends. A `:gen_event` handler that raises is removed
  # without notice, and `send/2` to a dead pid cannot raise.

  @behaviour :gen_event

  @manager :erl_signal_server

  @doc """
  Start delivering `signals` to `pid`. The handler is supervised by the
  calling process: `:gen_event` removes it when the caller exits, so a
  brutally killed caller does not leave it behind.
  """
  @spec install(pid(), [atom()]) :: :ok | {:error, term()}
  def install(pid, signals) when is_pid(pid) and is_list(signals) do
    case :gen_event.add_sup_handler(@manager, handler_id(pid), {pid, signals}) do
      :ok ->
        Enum.each(signals, &:os.set_signal(&1, :handle))

      {:error, _} = error ->
        error

      {:EXIT, reason} ->
        {:error, reason}
    end
  end

  @doc "Stop delivering signals to `pid`. Signal dispositions are left as they are."
  @spec uninstall(pid()) :: :ok
  def uninstall(pid) when is_pid(pid) do
    _ = :gen_event.delete_handler(@manager, handler_id(pid), :uninstall)
    :ok
  end

  # One handler per receiving process, so two apps (or a test alongside an
  # app) do not replace each other's.
  defp handler_id(pid), do: {__MODULE__, pid}

  @impl :gen_event
  def init({pid, signals}), do: {:ok, {pid, signals}}

  @impl :gen_event
  def handle_event(signal, {pid, signals} = state) do
    if signal in signals, do: send(pid, {:signal, signal})
    {:ok, state}
  end

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}
end
