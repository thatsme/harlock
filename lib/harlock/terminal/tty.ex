defmodule Harlock.Terminal.Tty do
  @moduledoc false
  # /dev/tty byte-stream primitives.
  #
  # Erlang raw file handles (`:file.open` with `:raw`) are bound to the
  # opening process — only that process can read or write. So in the
  # supervised path Writer must open its own write fd and Reader's read
  # process must open its own read fd. The shared-fd pattern only works
  # for one-process-owns-everything cases like the smoke functions below.
  #
  # Termios state (raw mode + restoration) and TIOCGWINSZ live in
  # `Harlock.Terminal.Termios` — they go through a NIF rather than `:os.cmd`
  # because `:os.cmd` subprocesses are `setsid()`-detached by ERTS's
  # `erl_child_setup` and have no access to /dev/tty.

  alias Harlock.Terminal.Ansi
  alias Harlock.Terminal.Termios

  @device ~c"/dev/tty"

  @type io_device :: :file.io_device()

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
  Helper for one-process smoke tests: opens a Termios control fd,
  snapshots, sets raw mode, opens read+write byte fds in the calling
  process, writes ANSI enter, runs the user function, then reverses
  everything in the right order. Even on exception from the user
  function, terminal state is restored.
  """
  @spec with_raw((io_device(), io_device() -> result)) ::
          result | {:error, term()}
        when result: var
  def with_raw(fun) when is_function(fun, 2) do
    with :ok <- check_platform(),
         {:ok, ctl} <- Termios.open(),
         {:ok, snap} <- Termios.get(ctl) do
      :ok = Termios.set_raw(ctl)

      try do
        do_with_fds(fun)
      after
        _ = Termios.set(ctl, snap)
        _ = Termios.close(ctl)
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
