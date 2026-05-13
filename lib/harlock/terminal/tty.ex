# credo:disable-for-this-file Credo.Check.Warning.UnsafeExec
# Disabled: this file deliberately uses `:os.cmd/1` to invoke `stty` with
# static charlist arguments. The check is correct in general but the inputs
# here are compile-time constants, not user data.
defmodule Harlock.Terminal.Tty do
  @moduledoc false
  # /dev/tty primitives.
  #
  # Erlang raw file handles (`:file.open` with `:raw`) are bound to the
  # opening process — only that process can read or write. So in the
  # supervised path Writer must open its own write fd and Reader's read
  # process must open its own read fd. The shared-fd pattern only works for
  # one-process-owns-everything cases like the smoke functions.
  #
  # Termios state (raw mode) is process-independent — set once globally on
  # the tty device. We manage it via the standard `stty` binary, snapshotting
  # with `stty -g` and restoring byte-for-byte.

  alias Harlock.Terminal.Ansi

  @device ~c"/dev/tty"

  @type io_device :: :file.io_device()

  @doc "Snapshot the current termios state so it can be restored verbatim."
  @spec snapshot_termios() :: {:ok, String.t()} | {:error, :tty_not_available}
  def snapshot_termios do
    case :os.cmd(~c"stty -g </dev/tty 2>/dev/null") do
      [] ->
        {:error, :tty_not_available}

      bytes ->
        case bytes |> List.to_string() |> String.trim() do
          "" -> {:error, :tty_not_available}
          snap -> {:ok, snap}
        end
    end
  end

  @doc "Put the tty into the raw-mode settings Harlock expects."
  @spec set_raw_mode() :: :ok
  def set_raw_mode do
    _ = :os.cmd(~c"stty raw -echo -icanon min 1 time 0 </dev/tty")
    :ok
  end

  @doc """
  Restore termios from a snapshot. Falls back to `stty sane` if no snapshot
  is supplied; that's a "factory reset" rather than a true restore, but it's
  the right move when we have nothing better.
  """
  @spec restore_termios(String.t() | nil) :: :ok
  def restore_termios(snap) when is_binary(snap) and snap != "" do
    cmd = ~c"stty " ++ String.to_charlist(snap) ++ ~c" </dev/tty 2>/dev/null"
    _ = :os.cmd(cmd)
    :ok
  end

  def restore_termios(_) do
    _ = :os.cmd(~c"stty sane </dev/tty 2>/dev/null")
    :ok
  end

  @doc """
  Query the current terminal size by shelling out to `stty size`.

  One shell-out per call (~3–5ms on macOS). Intended to be called only on
  SIGWINCH, not per-frame.
  """
  @spec size() :: {:ok, pos_integer(), pos_integer()} | {:error, term()}
  def size do
    case :os.cmd(~c"stty size </dev/tty 2>/dev/null") do
      [] ->
        {:error, :tty_not_available}

      bytes ->
        bytes
        |> List.to_string()
        |> String.trim()
        |> parse_size()
    end
  end

  defp parse_size(""), do: {:error, :tty_not_available}

  defp parse_size(str) do
    with [rows_str, cols_str] <- String.split(str, " ", trim: true),
         {rows, ""} when rows > 0 <- Integer.parse(rows_str),
         {cols, ""} when cols > 0 <- Integer.parse(cols_str) do
      {:ok, rows, cols}
    else
      _ -> {:error, {:parse_error, str}}
    end
  end

  @spec open_write() :: {:ok, io_device()} | {:error, term()}
  def open_write, do: :file.open(@device, [:write, :raw, :binary])

  @spec open_read() :: {:ok, io_device()} | {:error, term()}
  def open_read, do: :file.open(@device, [:read, :raw, :binary])

  @spec close(io_device()) :: :ok | {:error, term()}
  def close(fd), do: :file.close(fd)

  @spec write(io_device(), iodata()) :: :ok | {:error, term()}
  def write(fd, data), do: :file.write(fd, data)

  @spec read(io_device(), pos_integer()) :: {:ok, binary()} | :eof | {:error, term()}
  def read(fd, max), do: :file.read(fd, max)

  @doc """
  Helper for one-process smoke tests: snapshots termios, sets raw mode,
  opens read+write fds (in the calling process), writes ANSI enter, runs
  the user function, then reverses everything in the right order. Even on
  exception from the user function, terminal state is restored.
  """
  @spec with_raw((io_device(), io_device() -> result)) ::
          result | {:error, term()}
        when result: var
  def with_raw(fun) when is_function(fun, 2) do
    with :ok <- check_platform(),
         {:ok, snap} <- snapshot_termios() do
      :ok = set_raw_mode()

      try do
        do_with_fds(fun)
      after
        restore_termios(snap)
      end
    end
  end

  defp do_with_fds(fun) do
    {:ok, rfd} = open_read()

    try do
      {:ok, wfd} = open_write()

      try do
        :ok = write(wfd, Ansi.enter())

        try do
          fun.(rfd, wfd)
        after
          _ = write(wfd, Ansi.leave())
        end
      after
        _ = close(wfd)
      end
    after
      _ = close(rfd)
    end
  end

  defp check_platform do
    case :os.type() do
      {:unix, _} -> :ok
      other -> {:error, {:unsupported_platform, other}}
    end
  end
end
