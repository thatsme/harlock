defmodule Harlock.Element do
  @moduledoc """
  A node in the view tree returned by an app's `view/1`. Plain struct, no
  macros — built via the constructor functions in `Harlock.Elements`
  (`text/2`, `vbox/1`, `box/1`, etc.).

  You'll see `Harlock.Element.t()` in typespecs but normally won't
  construct one directly. Pattern-matching against the struct is fine
  if you're writing renderer extensions; the field shapes are stable
  on `0.x` releases.
  """

  defstruct [:type, :opts, :children]

  @type type ::
          :text
          | :text_input
          | :vbox
          | :hbox
          | :spacer
          | :box
          | :overlay
          | :table
          | :viewport
          | :progress
          | :spinner
          | :statusbar
          | :keybar
          | :tabs
  @type t :: %__MODULE__{
          type: type(),
          opts: keyword(),
          children: [t()]
        }
end
