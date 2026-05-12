defmodule Harlock.Terminal.Input.Parser do
  @moduledoc false
  # Pure byte → event state machine. Holds an internal buffer for partial
  # multi-byte sequences (CSI, SS3, bracketed paste, UTF-8) so the Reader can
  # feed arbitrary chunks without splitting events.
  #
  # Events emitted in v0.1:
  #   {:key, key, mods}        key ∈ :enter|:tab|:backspace|:escape|:up|:down|
  #                            :left|:right|:home|:end|:page_up|:page_down|
  #                            :insert|:delete|{:f, n}|{:char, codepoint}
  #                            mods ⊆ [:ctrl, :shift, :alt]
  #   {:paste, binary}         bracketed paste content
  #   {:focus, :in | :out}     XTerm focus reporting
  #
  # Deferred to v0.2: mouse events, kitty keyboard protocol, modified arrows
  # (CSI 1;<mod><letter>), Esc-alone vs Esc-prefix timing disambiguation.
  # In v0.1, lone ESC at end of a chunk → :escape; ESC followed by another
  # byte in the same chunk → either CSI/SS3 (if [, O) or Alt-prefixed key.

  defstruct buffer: <<>>

  @type key ::
          :enter
          | :tab
          | :backspace
          | :escape
          | :up
          | :down
          | :left
          | :right
          | :home
          | :end
          | :page_up
          | :page_down
          | :insert
          | :delete
          | {:f, 1..12}
          | {:char, non_neg_integer()}

  @type mods :: [:ctrl | :shift | :alt]
  @type event ::
          {:key, key(), mods()}
          | {:paste, binary()}
          | {:focus, :in | :out}
          | {:unknown_csi, binary(), byte()}
          | {:unknown_ss3, byte()}

  @type t :: %__MODULE__{buffer: binary()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {[event()], t()}
  def feed(%__MODULE__{buffer: buf}, bytes) when is_binary(bytes) do
    parse(buf <> bytes, [])
  end

  # -- Bracketed paste --------------------------------------------------------

  defp parse(<<"\e[200~", rest::binary>>, events) do
    case :binary.match(rest, "\e[201~") do
      {pos, 6} ->
        paste = binary_part(rest, 0, pos)
        remaining = binary_part(rest, pos + 6, byte_size(rest) - pos - 6)
        parse(remaining, [{:paste, paste} | events])

      :nomatch ->
        # Hold until we see the end marker.
        finish("\e[200~" <> rest, events)
    end
  end

  # -- CSI: ESC [ <params> <final> -------------------------------------------

  defp parse(<<"\e[", rest::binary>>, events) do
    case take_csi(rest, <<>>) do
      {:ok, params, final, remaining} ->
        parse(remaining, [csi_event(params, final) | events])

      :incomplete ->
        finish("\e[" <> rest, events)
    end
  end

  # -- SS3: ESC O <final> (application-mode arrows, F1-F4 on some terms) -----

  defp parse(<<"\eO", c, rest::binary>>, events) when c in 0x40..0x7E do
    parse(rest, [ss3_event(c) | events])
  end

  defp parse(<<"\eO">>, events), do: finish("\eO", events)

  # -- Lone ESC at end of chunk → Escape key ---------------------------------

  defp parse(<<"\e">>, events) do
    finish_with_events([{:key, :escape, []} | events])
  end

  # -- ESC + printable char → Alt-prefixed key -------------------------------

  defp parse(<<"\e", c, rest::binary>>, events) when c in 0x20..0x7E do
    parse(rest, [{:key, {:char, c}, [:alt]} | events])
  end

  # -- Single control characters ---------------------------------------------

  defp parse(<<?\r, rest::binary>>, events), do: parse(rest, [{:key, :enter, []} | events])
  defp parse(<<?\n, rest::binary>>, events), do: parse(rest, [{:key, :enter, []} | events])
  defp parse(<<?\t, rest::binary>>, events), do: parse(rest, [{:key, :tab, []} | events])
  defp parse(<<0x7F, rest::binary>>, events), do: parse(rest, [{:key, :backspace, []} | events])
  defp parse(<<0x08, rest::binary>>, events), do: parse(rest, [{:key, :backspace, []} | events])

  # Ctrl-letter (excluding the special-cased 0x08, 0x09, 0x0A, 0x0D handled above)
  defp parse(<<c, rest::binary>>, events) when c in 0x01..0x07 or c in 0x0B..0x0C or c in 0x0E..0x1A do
    parse(rest, [{:key, {:char, c + ?a - 1}, [:ctrl]} | events])
  end

  # -- ASCII printable -------------------------------------------------------

  defp parse(<<c, rest::binary>>, events) when c in 0x20..0x7E do
    parse(rest, [{:key, {:char, c}, []} | events])
  end

  # -- UTF-8 multibyte -------------------------------------------------------

  defp parse(<<cp::utf8, rest::binary>>, events) do
    parse(rest, [{:key, {:char, cp}, []} | events])
  end

  # -- Incomplete UTF-8 leader (high bit set, can't decode yet) --------------

  defp parse(<<c, _::binary>> = bin, events) when c >= 0x80 do
    finish(bin, events)
  end

  # -- Unknown low control byte we don't handle: drop --------------------

  defp parse(<<_::8, rest::binary>>, events), do: parse(rest, events)

  defp parse(<<>>, events), do: finish_with_events(events)

  # -- CSI takers ------------------------------------------------------------

  defp take_csi(<<>>, _acc), do: :incomplete

  defp take_csi(<<c, rest::binary>>, acc) when c in 0x40..0x7E do
    {:ok, acc, c, rest}
  end

  defp take_csi(<<c, rest::binary>>, acc) when c in 0x20..0x3F do
    take_csi(rest, acc <> <<c>>)
  end

  defp take_csi(_, _), do: :incomplete

  # -- CSI dispatch ----------------------------------------------------------

  defp csi_event("", ?A), do: {:key, :up, []}
  defp csi_event("", ?B), do: {:key, :down, []}
  defp csi_event("", ?C), do: {:key, :right, []}
  defp csi_event("", ?D), do: {:key, :left, []}
  defp csi_event("", ?H), do: {:key, :home, []}
  defp csi_event("", ?F), do: {:key, :end, []}
  defp csi_event("", ?Z), do: {:key, :tab, [:shift]}
  defp csi_event("", ?I), do: {:focus, :in}
  defp csi_event("", ?O), do: {:focus, :out}

  defp csi_event("1", ?~), do: {:key, :home, []}
  defp csi_event("2", ?~), do: {:key, :insert, []}
  defp csi_event("3", ?~), do: {:key, :delete, []}
  defp csi_event("4", ?~), do: {:key, :end, []}
  defp csi_event("5", ?~), do: {:key, :page_up, []}
  defp csi_event("6", ?~), do: {:key, :page_down, []}
  defp csi_event("7", ?~), do: {:key, :home, []}
  defp csi_event("8", ?~), do: {:key, :end, []}
  defp csi_event("11", ?~), do: {:key, {:f, 1}, []}
  defp csi_event("12", ?~), do: {:key, {:f, 2}, []}
  defp csi_event("13", ?~), do: {:key, {:f, 3}, []}
  defp csi_event("14", ?~), do: {:key, {:f, 4}, []}
  defp csi_event("15", ?~), do: {:key, {:f, 5}, []}
  defp csi_event("17", ?~), do: {:key, {:f, 6}, []}
  defp csi_event("18", ?~), do: {:key, {:f, 7}, []}
  defp csi_event("19", ?~), do: {:key, {:f, 8}, []}
  defp csi_event("20", ?~), do: {:key, {:f, 9}, []}
  defp csi_event("21", ?~), do: {:key, {:f, 10}, []}
  defp csi_event("23", ?~), do: {:key, {:f, 11}, []}
  defp csi_event("24", ?~), do: {:key, {:f, 12}, []}

  defp csi_event(params, final), do: {:unknown_csi, params, final}

  # -- SS3 dispatch ----------------------------------------------------------

  defp ss3_event(?A), do: {:key, :up, []}
  defp ss3_event(?B), do: {:key, :down, []}
  defp ss3_event(?C), do: {:key, :right, []}
  defp ss3_event(?D), do: {:key, :left, []}
  defp ss3_event(?H), do: {:key, :home, []}
  defp ss3_event(?F), do: {:key, :end, []}
  defp ss3_event(?P), do: {:key, {:f, 1}, []}
  defp ss3_event(?Q), do: {:key, {:f, 2}, []}
  defp ss3_event(?R), do: {:key, {:f, 3}, []}
  defp ss3_event(?S), do: {:key, {:f, 4}, []}
  defp ss3_event(c), do: {:unknown_ss3, c}

  # -- Helpers ---------------------------------------------------------------

  defp finish(buffer, events) do
    {Enum.reverse(events), %__MODULE__{buffer: buffer}}
  end

  defp finish_with_events(events) do
    {Enum.reverse(events), %__MODULE__{buffer: <<>>}}
  end
end
