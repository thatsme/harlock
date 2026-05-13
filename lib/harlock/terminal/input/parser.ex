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
  defp parse(<<c, rest::binary>>, events)
       when c in 0x01..0x07 or c in 0x0B..0x0C or c in 0x0E..0x1A do
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

  # Modified arrows / Home / End — CSI 1;<mod><letter>
  #
  # Modifier byte encoding (xterm): n-1 is a bitfield where bit 0 = Shift,
  # bit 1 = Alt, bit 2 = Ctrl, bit 3 = Meta. So 2 = Shift, 5 = Ctrl,
  # 6 = Ctrl+Shift, 8 = Ctrl+Alt+Shift, etc.
  defp csi_event("1;" <> mod_str, letter) when letter in [?A, ?B, ?C, ?D, ?H, ?F] do
    case parse_modifier(mod_str) do
      {:ok, mods} -> {:key, arrow_key(letter), mods}
      :error -> {:unknown_csi, "1;" <> mod_str, letter}
    end
  end

  # Modified tilde-keys: CSI <n>;<mod>~ for PageUp/PageDown/Insert/Delete/Fn.
  defp csi_event(params, ?~) do
    case String.split(params, ";") do
      [n, mod_str] ->
        with {:ok, key} <- tilde_key(n),
             {:ok, mods} <- parse_modifier(mod_str) do
          {:key, key, mods}
        else
          _ -> {:unknown_csi, params, ?~}
        end

      _ ->
        {:unknown_csi, params, ?~}
    end
  end

  defp csi_event(params, final), do: {:unknown_csi, params, final}

  defp arrow_key(?A), do: :up
  defp arrow_key(?B), do: :down
  defp arrow_key(?C), do: :right
  defp arrow_key(?D), do: :left
  defp arrow_key(?H), do: :home
  defp arrow_key(?F), do: :end

  defp tilde_key("2"), do: {:ok, :insert}
  defp tilde_key("3"), do: {:ok, :delete}
  defp tilde_key("5"), do: {:ok, :page_up}
  defp tilde_key("6"), do: {:ok, :page_down}
  defp tilde_key("11"), do: {:ok, {:f, 1}}
  defp tilde_key("12"), do: {:ok, {:f, 2}}
  defp tilde_key("13"), do: {:ok, {:f, 3}}
  defp tilde_key("14"), do: {:ok, {:f, 4}}
  defp tilde_key("15"), do: {:ok, {:f, 5}}
  defp tilde_key("17"), do: {:ok, {:f, 6}}
  defp tilde_key("18"), do: {:ok, {:f, 7}}
  defp tilde_key("19"), do: {:ok, {:f, 8}}
  defp tilde_key("20"), do: {:ok, {:f, 9}}
  defp tilde_key("21"), do: {:ok, {:f, 10}}
  defp tilde_key("23"), do: {:ok, {:f, 11}}
  defp tilde_key("24"), do: {:ok, {:f, 12}}
  defp tilde_key(_), do: :error

  defp parse_modifier(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 2 and n <= 16 -> {:ok, decode_mod_byte(n)}
      _ -> :error
    end
  end

  # xterm modifier encoding: (n - 1) is a bitfield.
  defp decode_mod_byte(n) do
    bits = n - 1

    []
    |> maybe_add(:shift, Bitwise.band(bits, 1) != 0)
    |> maybe_add(:alt, Bitwise.band(bits, 2) != 0)
    |> maybe_add(:ctrl, Bitwise.band(bits, 4) != 0)
    |> maybe_add(:meta, Bitwise.band(bits, 8) != 0)
  end

  defp maybe_add(mods, atom, true), do: mods ++ [atom]
  defp maybe_add(mods, _atom, false), do: mods

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
