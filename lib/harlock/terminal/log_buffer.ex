defmodule Harlock.Terminal.LogBuffer do
  @moduledoc false
  # Keeps log output off the screen while an app owns the terminal, and prints
  # it once the terminal is handed back.
  #
  # Erlang's console handlers write each event straight to standard_io or
  # standard_error, which is the same terminal Harlock is drawing on: a log line
  # lands in the middle of a frame, and because the renderer only redraws cells
  # it believes changed, it stays there. Dropping those events instead would
  # lose the one message a user most needs after a crash — the runtime logs a
  # render crash itself.
  #
  # So for the length of a session each console handler is muted by level, and
  # a mirror handler with the same level, filters and formatter sends every
  # event it would have written to the owner (Keeper). The owner keeps the most
  # recent ones and, after restoring the terminal, releases the handlers and
  # writes what it kept, formatted exactly as the console would have.
  #
  # The mirror runs in the logging process, so it only sends; formatting waits
  # for the replay.

  @limit 500

  @type captured :: [{:logger.handler_id(), :logger.level() | :all | :none, atom()}]
  @type buffer :: %{events: :queue.queue(), size: non_neg_integer(), dropped: non_neg_integer()}

  @doc "Mute every console handler, mirroring each into `owner`'s mailbox."
  @spec capture(pid()) :: captured()
  def capture(owner) do
    for {id, config} <- console_handlers() do
      mirror = :"harlock_log_buffer_#{id}"

      # A session killed outright never released its mirror; replace it rather
      # than fail to start.
      _ = :logger.remove_handler(mirror)

      :ok =
        :logger.add_handler(mirror, __MODULE__, %{
          level: config.level,
          filters: Map.get(config, :filters, []),
          filter_default: Map.get(config, :filter_default, :log),
          formatter: config.formatter,
          config: %{owner: owner}
        })

      :ok = :logger.update_handler_config(id, :level, :none)
      {id, config.level, mirror}
    end
  end

  @doc "Remove the mirrors and give the console handlers their levels back."
  @spec release(captured()) :: :ok
  def release(captured) do
    for {id, level, mirror} <- captured do
      _ = :logger.remove_handler(mirror)
      _ = :logger.update_handler_config(id, :level, level)
    end

    :ok
  end

  @spec new() :: buffer()
  def new, do: %{events: :queue.new(), size: 0, dropped: 0}

  @doc "Keep an event, dropping the oldest past the limit."
  @spec push(buffer(), {term(), :logger.log_event()}) :: buffer()
  def push(%{size: size} = buffer, item) when size < @limit,
    do: %{buffer | events: :queue.in(item, buffer.events), size: size + 1}

  def push(buffer, item) do
    {_, events} = :queue.out(buffer.events)
    %{buffer | events: :queue.in(item, events), dropped: buffer.dropped + 1}
  end

  @doc """
  Collect events still in the mailbox, then write everything kept, oldest
  first. Call after `release/1`, so nothing more arrives.
  """
  @spec replay(buffer()) :: :ok
  def replay(buffer) do
    buffer = drain(buffer)

    if buffer.dropped > 0 do
      IO.write(:standard_io, "\n… #{buffer.dropped} earlier log events not kept\n")
    end

    for {{module, config}, event} <- :queue.to_list(buffer.events) do
      IO.write(:standard_io, format(module, config, event))
    end

    :ok
  end

  defp drain(buffer) do
    receive do
      {:harlock_log, formatter, event} -> buffer |> push({formatter, event}) |> drain()
    after
      0 -> buffer
    end
  end

  # A formatter that raises must not take the rest of the replay with it.
  defp format(module, config, event) do
    module.format(event, config)
  rescue
    _ -> "\n#{inspect(event.level)} #{inspect(event.msg)}\n"
  end

  defp console_handlers do
    for id <- :logger.get_handler_ids(),
        {:ok, %{module: :logger_std_h, config: %{type: type}} = config} <- [
          :logger.get_handler_config(id)
        ],
        type in [:standard_io, :standard_error],
        config.level != :none,
        do: {id, config}
  end

  # -- :logger handler callback ----------------------------------------------

  @doc false
  def log(event, %{formatter: formatter, config: %{owner: owner}}) do
    send(owner, {:harlock_log, formatter, event})
    :ok
  end
end
