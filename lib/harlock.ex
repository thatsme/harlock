defmodule Harlock do
  @moduledoc """
  Harlock — a pure-Elixir TUI framework for Unix terminals.

  The two entry points:

    * `Harlock.run/2` — blocking. Starts the app, returns when it exits.
    * `Harlock.start_link/2` — non-blocking. Returns a supervisor pid for
      embedding inside an existing OTP application.

  v0.1 is under construction; the smoke functions are scaffold tooling.
  """

  alias Harlock.Terminal.{Ansi, Caps, Tty}
  _ = Caps

  @type app :: module()
  @type init_arg :: any()

  @doc """
  Start an app and block until it exits.

  Returns:

    * `{:ok, reason}` when the app ends itself — `update/2` returned `:quit`, or
      the runtime reported why it stopped.
    * `{:error, reason}` when the supervisor could not start, or went down
      without the app ending itself, e.g. after a crash in `update/2`. The
      terminal has been restored either way.

  The caller is linked to the app supervisor, so killing the caller tears the
  app down and restores the terminal. The link does not work the other way:
  while `run/3` waits it traps exits, so the app going down is a return value
  rather than an exit signal that kills the caller. Exit trapping is put back as
  it was before returning, and an abnormal exit from any *other* process linked
  to the caller still ends it, after stopping the app, as it would have without
  `run/3` in between.

  Options:

    * `:theme` — a `Harlock.Theme.t()` (or keyword list / map convertible
      via `Harlock.Theme.build/1`). Defaults to `Harlock.Theme.default/0`.
    * `:mouse` — turn on mouse reporting (default `false`). Clicks focus
      elements and press buttons and checkboxes, the wheel scrolls viewports
      and tables, and anything not routed arrives in `update/2` as
      `{:mouse, action, button, col, row, mods}`. See `Harlock.App`. Off by
      default because while it is on the terminal's own click-and-drag text
      selection needs a modifier (usually Shift, or Option on macOS).
  """
  @spec run(app(), init_arg(), keyword()) :: {:ok, term()} | {:error, term()}
  def run(app, init_arg \\ nil, opts \\ []) do
    sup_opts =
      [app: app, init_arg: init_arg, caller: self(), mouse: Keyword.get(opts, :mouse, false)]
      |> maybe_put_theme(opts)

    was_trapping = Process.flag(:trap_exit, true)

    try do
      case Harlock.App.Supervisor.start_link(sup_opts) do
        {:ok, sup} ->
          await_app(sup, was_trapping)

        {:error, reason} = err ->
          drop_exit_with_reason(reason)
          err
      end
    after
      Process.flag(:trap_exit, was_trapping)
    end
  end

  defp await_app(sup, was_trapping) do
    receive do
      {:harlock_done, reason} ->
        stop_supervisor(sup)
        {:ok, reason}

      {:EXIT, ^sup, reason} ->
        {:error, reason}

      # Only a caller that was not trapping would have been killed by this; one
      # that was keeps receiving it as a message, so leave that mailbox alone.
      {:EXIT, _other, reason} when not was_trapping and reason != :normal ->
        stop_supervisor(sup)
        exit(reason)

      # ...and a normal exit, which would have been ignored, is dropped.
      {:EXIT, _other, :normal} when not was_trapping ->
        await_app(sup, was_trapping)
    end
  end

  # A supervisor that fails to start has also exited, and with exits trapped
  # that arrives as a message carrying the same reason.
  defp drop_exit_with_reason(reason) do
    receive do
      {:EXIT, _pid, ^reason} -> :ok
    after
      100 -> :ok
    end
  end

  # Supervisor.stop/2 returns once the tree is down. Its exit arrives here as a
  # message because exits are trapped; drop it so it does not outlive run/3.
  # The runtime can also report a render error and then crash, which already
  # shuts the tree down, so the supervisor may be gone by the time it is asked.
  defp stop_supervisor(sup) do
    Supervisor.stop(sup, :normal)
  catch
    :exit, _ -> :ok
  after
    receive do
      {:EXIT, ^sup, _} -> :ok
    after
      1_000 -> :ok
    end
  end

  @doc """
  Start an app under the caller's supervision tree without blocking.

  Returns `{:ok, sup_pid}`. The caller is responsible for handling the
  supervisor's lifecycle (linking, monitoring, stopping). Useful when
  embedding Harlock inside a larger OTP app — e.g. a Phoenix project with a
  dev-mode TUI dashboard.

  Accepts the same options as `run/3`.
  """
  @spec start_link(app(), init_arg(), keyword()) :: Supervisor.on_start()
  def start_link(app, init_arg \\ nil, opts \\ []) do
    sup_opts =
      [app: app, init_arg: init_arg, caller: self(), mouse: Keyword.get(opts, :mouse, false)]
      |> maybe_put_theme(opts)

    Harlock.App.Supervisor.start_link(sup_opts)
  end

  defp maybe_put_theme(sup_opts, opts) do
    case Keyword.fetch(opts, :theme) do
      {:ok, theme} -> Keyword.put(sup_opts, :theme, Harlock.Theme.build(theme))
      :error -> sup_opts
    end
  end

  @doc """
  Round-trip smoke test. Opens /dev/tty, writes a greeting in the alt-screen,
  reads up to 5 bytes from the user, echoes what was typed, and restores the
  terminal. Should leave the terminal in a usable state after returning.
  """
  @spec smoke() :: binary() | {:error, term()}
  def smoke do
    Tty.with_raw(fn rfd, wfd ->
      :ok = Tty.write(wfd, [Ansi.move(1, 2), "Harlock smoke test."])
      :ok = Tty.write(wfd, [Ansi.move(3, 2), "Press 5 keys..."])
      bytes = read_n(rfd, 5, [])
      :ok = Tty.write(wfd, [Ansi.move(5, 2), "You typed: ", inspect(bytes)])
      Process.sleep(1200)
      bytes
    end)
  end

  @doc """
  Crash-path smoke test. Spawns a linked child that opens /dev/tty and then
  raises. `with_raw`'s nested `try/after` blocks restore the terminal before
  the process dies. Returns `{cleanup, reason}` where cleanup is `:ok` if
  the restore ran.
  """
  @spec smoke_crash() :: {:ok | :no_cleanup | term(), term()}
  def smoke_crash do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        try do
          Tty.with_raw(fn _rfd, wfd ->
            :ok = Tty.write(wfd, [Ansi.move(1, 2), "About to crash..."])
            Process.sleep(400)
            raise "intentional crash to verify terminal restoration"
          end)
        after
          send(parent, :cleanup_ran)
        end
      end)

    cleanup =
      receive do
        :cleanup_ran -> :ok
      after
        5_000 -> :no_cleanup
      end

    reason =
      receive do
        {:DOWN, ^ref, :process, ^pid, r} -> r
      after
        2_000 -> :no_exit
      end

    {cleanup, reason}
  end

  defp read_n(_fd, remaining, acc) when remaining <= 0 do
    acc |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp read_n(fd, remaining, acc) do
    case Tty.read(fd, max(remaining, 16)) do
      {:ok, bytes} ->
        read_n(fd, remaining - byte_size(bytes), [bytes | acc])

      {:error, :eintr} ->
        read_n(fd, remaining, acc)

      :eof ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      {:error, _reason} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
