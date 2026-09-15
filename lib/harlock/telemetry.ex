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

  One span per call to `update/2`, from the event reaching it to the frame that
  follows being drawn — so the frame's own render span sits inside it. Catches
  keystroke-to-screen lag. `event` is the message `update/2` received, which
  after routing is the widget message rather than the raw key. One input can
  make several spans: a click that selects and activates a menu item calls
  `update/2` twice, and a move of focus adds one for
  `{:harlock_focus, from, to}`.

    * **measurements** (on `:stop`): `%{duration: native, monotonic_time: native}`
    * **metadata** (on `:stop`): `%{app: module, event: term, focused: term}`

  ### `[:harlock, :cmd, :dispatch]`

  Emitted when the runtime dispatches a `Cmd` returned from `init/1` or
  `update/2`.

    * **measurements**: `%{count: 1}`
    * **metadata**: `%{kind: :fun | :batch | :map | :none | :exec | :suspend}`

  ### `[:harlock, :cmd, :complete]`

  Emitted when a `Cmd.from/1` task returns (success or `{:cmd_error, _}`).
  `exec` and `suspend` are carried out by the runtime rather than a task and do
  not emit it.

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
