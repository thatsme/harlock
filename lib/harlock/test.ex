defmodule Harlock.Test do
  @moduledoc """
  Test harness for Harlock apps.

  Boots an app under a `:test` backend — no `/dev/tty` required — then
  exposes synchronous helpers for driving events and inspecting state.

      test "tab moves focus to next field" do
        h = Harlock.Test.start_app(MyApp, %{...})
        Harlock.Test.send_key(h, :tab)
        assert Harlock.Test.focused(h) == :email_field
        Harlock.Test.stop(h)
      end

  Anything that requires a real terminal lives behind the backend
  abstraction; everything tested here is the same code path that runs in
  production except for the bytes-in/bytes-out boundary.
  """

  alias Harlock.App.Supervisor, as: AppSupervisor
  alias Harlock.IO.Test.{Reader, Writer}

  @type handle :: %{
          sup: pid(),
          name: atom(),
          writer: atom(),
          reader: atom(),
          runtime: atom()
        }

  @doc """
  Start an app under the test backend and return a handle for the helpers
  in this module.
  """
  @spec start_app(module(), any(), keyword()) :: handle()
  def start_app(app, init_arg \\ nil, opts \\ []) do
    name =
      Keyword.get_lazy(opts, :name, fn ->
        :"harlock_test_#{System.unique_integer([:positive])}"
      end)

    rows = Keyword.get(opts, :rows, 24)
    cols = Keyword.get(opts, :cols, 80)

    {:ok, sup} =
      AppSupervisor.start_link(
        app: app,
        init_arg: init_arg,
        caller: self(),
        name: name,
        backend: :test,
        rows: rows,
        cols: cols
      )

    handle = %{
      sup: sup,
      name: name,
      writer: :"#{name}.Writer",
      reader: :"#{name}.Reader",
      runtime: :"#{name}.Runtime"
    }

    # Give the runtime a render tick to lay down the first frame.
    sync(handle)
    handle
  end

  @doc """
  Stop the app cleanly. Safe to call after the app has already quit on its
  own (e.g. via update returning `:quit`). Drains any pending
  `:harlock_done` message from the calling process's mailbox.
  """
  @spec stop(handle()) :: :ok
  def stop(handle) do
    try do
      Supervisor.stop(handle.sup, :normal)
    catch
      :exit, _ -> :ok
    end

    receive do
      {:harlock_done, _} -> :ok
    after
      0 -> :ok
    end

    :ok
  end

  @doc """
  Returns true if the app has signaled `:quit` from its update callback.
  The runtime exits but the supervisor stays alive until you call `stop/1`.
  """
  @spec quit?(handle()) :: boolean()
  def quit?(handle) do
    Process.whereis(handle.runtime) == nil
  end

  @doc """
  Inject a synthetic event into the runtime. The event uses the same shape
  the input parser emits (e.g. `{:key, :tab, []}`).
  """
  @spec send_event(handle(), any()) :: :ok
  def send_event(handle, event) do
    try do
      Reader.inject(handle.reader, event)
    catch
      :exit, _ -> :ok
    end

    sync(handle)
  end

  @doc """
  Convenience for `{:key, key, mods}` events.

      Harlock.Test.send_key(h, :tab)
      Harlock.Test.send_key(h, {:char, ?q})
      Harlock.Test.send_key(h, :enter, [:ctrl])
  """
  @spec send_key(handle(), any(), [atom()]) :: :ok
  def send_key(handle, key, mods \\ []) do
    send_event(handle, {:key, key, mods})
  end

  @doc """
  Inject a resize event. Stand-in for SIGWINCH in headless tests — the
  runtime updates its dimensions, discards `prev_frame`, and re-renders.
  The test writer's cell buffer is resized first so the new frame has
  somewhere to land.
  """
  @spec resize(handle(), pos_integer(), pos_integer()) :: :ok
  def resize(handle, rows, cols) when rows > 0 and cols > 0 do
    :ok = Writer.set_size(handle.writer, rows, cols)
    send(handle.runtime, {:harlock_resize, rows, cols})
    sync(handle)
  end

  @doc "Returns the rendered cell buffer as a single string (rows joined by \\n)."
  @spec render(handle()) :: String.t()
  def render(handle), do: Writer.to_string(handle.writer)

  @doc "Returns the current cell buffer struct."
  @spec cells(handle()) :: Harlock.Render.Buffer.t()
  def cells(handle), do: Writer.buffer(handle.writer)

  @doc "Returns the id of the currently focused element, or nil."
  @spec focused(handle()) :: any()
  def focused(handle), do: :sys.get_state(handle.runtime).focused

  @doc "Returns the current model from the runtime."
  @spec model(handle()) :: any()
  def model(handle), do: :sys.get_state(handle.runtime).model

  @doc "Returns the raw bytes the writer has received so far."
  @spec raw_writes(handle()) :: binary()
  def raw_writes(handle), do: Writer.raw_writes(handle.writer)

  # Drain the runtime mailbox. The runtime renders synchronously inside each
  # event handler, so by the time :sys.get_state returns, the current frame
  # is already on the writer — no extra sleep needed.
  defp sync(handle) do
    try do
      _ = :sys.get_state(handle.runtime)
    catch
      :exit, _ -> :ok
    end

    :ok
  end
end
