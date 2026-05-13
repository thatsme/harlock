defmodule Harlock.Telemetry do
  @moduledoc """
  Telemetry events emitted by the Harlock runtime.

  Attach handlers in your app's startup (`Application.start/2`) or in
  tests:

      :telemetry.attach(
        "log-frame-duration",
        [:harlock, :frame, :render, :stop],
        fn _event, %{duration: duration}, _meta, _ ->
          IO.puts("frame: \#{System.convert_time_unit(duration, :native, :microsecond)}µs")
        end,
        nil
      )

  All durations come from `:telemetry.span/3` (`:native` time units —
  use `System.convert_time_unit/3` to format).

  ## Events

  ### `[:harlock, :frame, :render, :start]` / `[..., :stop]` / `[..., :exception]`

  Wraps `view/1` + tree traversal + diff emission for one frame.

    * **measurements** (on `:stop`): `%{duration: native, monotonic_time: native}`
    * **metadata** (on `:stop`): `%{app: module, dirty: boolean, rows: integer, cols: integer}`

  ### `[:harlock, :input, :dispatch, :start]` / `[..., :stop]` / `[..., :exception]`

  Wraps the path from event arrival in the runtime mailbox to the
  return of `update/2`. Catches keystroke-to-model lag.

    * **measurements** (on `:stop`): `%{duration: native, monotonic_time: native}`
    * **metadata** (on `:stop`): `%{app: module, event: term, focused: term}`

  ### `[:harlock, :cmd, :dispatch]`

  Emitted when a `Cmd` is handed to the task supervisor.

    * **measurements**: `%{count: 1}`
    * **metadata**: `%{kind: :fun | :batch | :map | :none}`

  ### `[:harlock, :cmd, :complete]`

  Emitted when a `Cmd` task returns (success or `{:cmd_error, _}`).

    * **measurements**: `%{duration: native}`
    * **metadata**: `%{status: :ok | :error}`

  ### `[:harlock, :reader, :tty_lost]`

  One-shot when the input reader sees EOF on `/dev/tty` (ssh disconnect,
  terminal close, etc.). Useful for an oncall alert.

    * **measurements**: `%{count: 1}`
    * **metadata**: `%{reason: :eof | term}`
  """

  @doc false
  def event_names do
    [
      [:harlock, :frame, :render, :start],
      [:harlock, :frame, :render, :stop],
      [:harlock, :frame, :render, :exception],
      [:harlock, :input, :dispatch, :start],
      [:harlock, :input, :dispatch, :stop],
      [:harlock, :input, :dispatch, :exception],
      [:harlock, :cmd, :dispatch],
      [:harlock, :cmd, :complete],
      [:harlock, :reader, :tty_lost]
    ]
  end
end
