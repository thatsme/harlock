defmodule Harlock.Terminal.Termios do
  @moduledoc """
  POSIX termios access for `/dev/tty` via a small NIF.

  Most Harlock apps don't touch this directly — the runtime owns one
  control fd for the app's lifecycle (snapshot on init, restore on
  terminate) and input is delivered via `arm_select/1` + `read_nonblock/2`.
  The module is documented so you can drive termios from your own
  code if you need raw mode outside the Harlock runtime.

  See `c_src/README.md` for the design rationale — in particular, why
  `tcgetattr` / `tcsetattr` / `ioctl(TIOCGWINSZ)` go through a NIF
  instead of `:os.cmd("stty ...")` (the subshell loses the controlling
  terminal) and why reads use `enif_select_read` + non-blocking
  `read(2)` instead of `:file.read/2` (the latter doesn't deliver
  bytes from a spawned process on macOS).
  """

  require Logger

  @on_load :load_nif

  @typedoc "Opaque resource — a /dev/tty fd."
  @opaque ref :: reference()

  @typedoc "Snapshot of termios attributes. Opaque to callers."
  @opaque attrs :: binary()

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:harlock), ~c"termios_nif")

    case :erlang.load_nif(path, 0) do
      :ok ->
        :ok

      {:error, {reason, info}} ->
        Logger.warning(
          "Harlock.Terminal.Termios NIF failed to load: #{inspect(reason)} #{inspect(info)}. " <>
            "Terminal control will be unavailable until the NIF builds."
        )

        :ok
    end
  end

  @doc """
  Open /dev/tty for termios control. Returns `{:error, :no_tty}` in
  environments without a controlling terminal (CI, piped stdin) so callers
  can detect non-interactive contexts cleanly.
  """
  @spec open() :: {:ok, ref()} | {:error, atom() | {atom(), term()}}
  def open, do: open_nif()

  @doc "Close the fd. Idempotent; the fd is also GC'd via NIF resource."
  @spec close(ref()) :: :ok
  def close(ref), do: close_nif(ref)

  @doc "Read current termios attributes. The returned binary is opaque."
  @spec get(ref()) :: {:ok, attrs()} | {:error, atom() | {atom(), term()}}
  def get(ref), do: get_nif(ref)

  @doc "Restore termios attributes from a prior `get/1` result."
  @spec set(ref(), attrs()) :: :ok | {:error, atom() | {atom(), term()}}
  def set(ref, attrs), do: set_nif(ref, attrs)

  @doc "Put the terminal in raw mode (cfmakeraw + VMIN=1, VTIME=0)."
  @spec set_raw(ref()) :: :ok | {:error, atom() | {atom(), term()}}
  def set_raw(ref), do: set_raw_nif(ref)

  @doc "Current window size in cells, via TIOCGWINSZ."
  @spec winsize(ref()) ::
          {:ok, pos_integer(), pos_integer()} | {:error, atom() | {atom(), term()}}
  def winsize(ref) do
    case winsize_nif(ref) do
      {:ok, {rows, cols}} -> {:ok, rows, cols}
      other -> other
    end
  end

  @doc """
  Register the fd with the BEAM IO poller for one read-ready notification.
  When the fd has data available, BEAM sends `{:tty_ready, ref}` to the
  process that called this function. Caller must re-arm after each read.

  Only the process that called `open/0` may arm/read — others get
  `{:error, :not_owner}`.
  """
  @spec arm_select(ref()) :: :ok | {:error, atom() | {atom(), term()}}
  def arm_select(ref), do: arm_select_nif(ref)

  @doc """
  Non-blocking `read(2)` of up to `max_bytes`. The fd is `O_NONBLOCK` so
  this returns `:wouldblock` when no data is ready (caller should
  `arm_select` and wait for the next `{:tty_ready, _}`). `:eof` means the
  tty was closed (ssh disconnect, tmux kill, etc.) — surface this to the
  app for clean shutdown.
  """
  @spec read_nonblock(ref(), pos_integer()) ::
          {:ok, binary()} | :wouldblock | :eof | {:error, atom() | {atom(), term()}}
  def read_nonblock(ref, max_bytes), do: read_nonblock_nif(ref, max_bytes)

  # -- NIF stubs. Replaced at module load. ----------------------------------

  defp open_nif, do: :erlang.nif_error(:nif_not_loaded)
  defp close_nif(_ref), do: :erlang.nif_error(:nif_not_loaded)
  defp get_nif(_ref), do: :erlang.nif_error(:nif_not_loaded)
  defp set_nif(_ref, _attrs), do: :erlang.nif_error(:nif_not_loaded)
  defp set_raw_nif(_ref), do: :erlang.nif_error(:nif_not_loaded)
  defp winsize_nif(_ref), do: :erlang.nif_error(:nif_not_loaded)
  defp arm_select_nif(_ref), do: :erlang.nif_error(:nif_not_loaded)
  defp read_nonblock_nif(_ref, _max), do: :erlang.nif_error(:nif_not_loaded)
end
