defmodule Harlock.Element do
  @moduledoc false
  # A node in the view tree. Plain struct, no macros — built by constructor
  # functions in Harlock.Elements. Pattern-matchable in the renderer, no
  # compile-time magic.

  defstruct [:type, :opts, :children]

  @type type :: :text | :text_input | :vbox | :hbox | :spacer | :box | :overlay | :table
  @type t :: %__MODULE__{
          type: type(),
          opts: keyword(),
          children: [t()]
        }
end
