defmodule Harlock.Sub.Logger do
  @moduledoc """
  `:logger` handler behind `Harlock.Sub.logger/1`, plus the helper for turning a
  delivered entry into text.

  The subscription delivers entries as maps:

      %{level: :warning, msg: raw_msg, meta: metadata}

  `msg` is Erlang's raw message term — `{:string, chardata}`, `{:report, map}`,
  or a `{format, args}` pair. It arrives unformatted on purpose: formatting
  allocates, and a log handler runs **inside the process that called
  `Logger.warning/1`**, so formatting there bills the caller for your UI. Call
  `text/1` from `update/2` instead, where the cost lands on the runtime:

      def update({:log, entry}, m) do
        line = Harlock.Sub.Logger.text(entry)
        %{m | lines: [line | m.lines]}
      end
  """

  @typedoc "A delivered log entry: the level, Erlang's raw message term, and metadata."
  @type entry :: %{level: :logger.level(), msg: term(), meta: map()}

  # -- lifetime --------------------------------------------------------------
  #
  # Same reasoning as Harlock.Sub.Telemetry: a :logger handler is a global
  # registration rather than a process, so nothing removes it when the app goes
  # away. This process exists to be the subscription's lifetime, and traps exits
  # because the runtime stops subs with Process.exit(pid, :shutdown), which would
  # otherwise kill it before it could remove the handler.

  @doc false
  @spec start_link(:logger.level(), [atom()] | :all, function() | nil, pid()) :: pid()
  def start_link(level, metadata, transform, target) do
    spawn_link(fn -> init(level, metadata, transform, target) end)
  end

  defp init(level, metadata, transform, target) do
    Process.flag(:trap_exit, true)
    id = handler_id(target)

    :ok =
      :logger.add_handler(id, __MODULE__, %{
        # Let :logger filter by level before calling us. Cheaper than receiving
        # everything and discarding it, and the discarding would happen in the
        # caller's process.
        level: level,
        config: %{target: target, metadata: metadata, transform: transform}
      })

    wait(id)
  end

  defp wait(id) do
    receive do
      {:EXIT, _from, _reason} -> :logger.remove_handler(id)
      _other -> wait(id)
    end
  end

  defp handler_id(target) do
    :"harlock_log_#{:erlang.pid_to_list(target)}"
  end

  # -- handler callback ------------------------------------------------------

  @doc false
  # Runs in the process that emitted the log call. Builds a term, sends it,
  # returns. Nothing here may raise, block, or log: raising gets the handler
  # removed by :logger, blocking stalls the caller, and logging would re-enter
  # this function forever.
  def log(%{level: level, msg: msg, meta: meta}, %{config: config}) do
    %{target: target, metadata: keys, transform: transform} = config

    entry = %{level: level, msg: msg, meta: select(meta, keys)}

    message =
      case transform do
        nil -> {:log, entry}
        fun when is_function(fun, 1) -> fun.(entry)
        _other -> {:log, entry}
      end

    send(target, {:harlock_event, message})
    :ok
  end

  def log(_event, _config), do: :ok

  defp select(meta, :all), do: meta
  defp select(meta, keys) when is_list(keys), do: Map.take(meta, keys)

  # -- formatting ------------------------------------------------------------

  @doc """
  Render a delivered entry's message as a binary.

  Handles all three shapes Erlang's `:logger` produces: `{:string, chardata}`,
  `{:report, term}`, and `{format, args}`. Call this on the runtime side rather
  than in a transform — a transform runs in the process that logged.
  """
  @spec text(entry() | term()) :: String.t()
  def text(%{msg: msg}), do: text(msg)

  def text({:string, chardata}), do: safe_chardata(chardata)

  def text({:report, report}) do
    # format_report/1 is specified to always return a {format, args} pair, so
    # there is no other shape to handle here.
    {format, args} = :logger.format_report(report)
    safe_format(format, args)
  end

  def text({format, args}) when is_list(args), do: safe_format(format, args)
  def text(other), do: inspect(other)

  # Formatting arbitrary logged terms must not itself raise — a log viewer that
  # crashes on a malformed entry is worse than one showing a placeholder.
  defp safe_format(format, args) do
    safe_chardata(:io_lib.format(format, args))
  rescue
    _ -> inspect({format, args})
  end

  defp safe_chardata(chardata) do
    IO.chardata_to_string(chardata)
  rescue
    _ -> inspect(chardata)
  end
end
