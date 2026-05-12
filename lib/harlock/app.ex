defmodule Harlock.App do
  @moduledoc """
  Behaviour for Harlock applications.

  An app defines three callbacks:

    * `init/1` — returns the initial model from an arbitrary init argument.
    * `update/2` — given an event and the current model, returns the next
      model, optionally paired with a `Cmd`. Return `:quit` to exit the app.
    * `view/1` — given the current model, returns an element tree.

  The simplest app:

      defmodule Counter do
        use Harlock.App

        def init(_), do: %{n: 0}

        def update({:key, {:char, ?+}, []}, m), do: %{m | n: m.n + 1}
        def update({:key, {:char, ?q}, []}, _), do: :quit
        def update(_event, m), do: m

        def view(m) do
          vbox(constraints: [length: 1, fill: 1], children: [
            text("Count: \#{m.n}"),
            text("(+ to inc, q to quit)")
          ])
        end
      end
  """

  alias Harlock.{Cmd, Element}

  @type model :: any()
  @type msg :: any()

  @callback init(any()) :: model() | {model(), Cmd.t()}
  @callback update(msg(), model()) :: model() | {model(), Cmd.t()} | :quit | {:quit, Cmd.t()}
  @callback view(model()) :: Element.t()
  @callback subs(model()) :: [Harlock.Sub.t()]

  @optional_callbacks subs: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Harlock.App
      import Harlock.Elements
      alias Harlock.{Cmd, Sub}
      alias Harlock.Render.Style
    end
  end
end
