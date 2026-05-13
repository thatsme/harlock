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
  # Lone ESC at end of a chunk → :escape; ESC followed by another byte in the
  # same chunk → either CSI/SS3 (if [, O) or Alt-prefixed key.
  #
  # Kitty keyboard protocol events (`u`-terminated CSI) are parsed but
  # require the application to push the enable flags via the Writer; the
  # runtime does not enable them by default in v0.3.

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

  @type mods :: [:ctrl | :shift | :alt | :meta]
  @type event ::
          {:key, key(), mods()}
          | {:key_repeat, key(), mods()}
          | {:key_release, key(), mods()}
          | {:paste, binary()}
          | {:focus, :in | :out}
          | {:capability, :kitty_keyboard, non_neg_integer()}
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

  # Kitty keyboard protocol — detection response: CSI ? <flags> u
  defp csi_event(<<"?", flags_str::binary>>, ?u) do
    case Integer.parse(flags_str) do
      {flags, ""} when flags >= 0 -> {:capability, :kitty_keyboard, flags}
      _ -> {:unknown_csi, "?" <> flags_str, ?u}
    end
  end

  # Kitty keyboard protocol — key event:
  #
  #   CSI <code>[:<shifted>[:<base>]][;<mods>[:<event>]] u
  #
  # `code` is the unicode codepoint of the unmodified key (or a kitty
  # private-range value for functional keys). `event` is 1=press (default),
  # 2=repeat, 3=release. Shifted/base alternate-key info is ignored.
  defp csi_event(params, ?u) do
    case parse_kitty_event(params) do
      {:ok, key, mods, event_type} -> kitty_event_tuple(event_type, key, mods)
      :error -> {:unknown_csi, params, ?u}
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
      {n, ""} when n >= 1 and n <= 16 -> {:ok, decode_mod_byte(n)}
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

  # -- Kitty keyboard helpers ------------------------------------------------

  defp parse_kitty_event(params) do
    {code_section, mods_section} =
      case String.split(params, ";", parts: 2) do
        [c] -> {c, nil}
        [c, m] -> {c, m}
      end

    with {:ok, code} <- parse_kitty_code(code_section),
         {:ok, mods, event_type} <- parse_kitty_mods(mods_section) do
      {:ok, kitty_key(code), mods, event_type}
    end
  end

  defp parse_kitty_code(section) do
    primary = section |> String.split(":", parts: 2) |> List.first()

    case Integer.parse(primary) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_kitty_mods(nil), do: {:ok, [], :press}

  defp parse_kitty_mods(section) do
    case String.split(section, ":", parts: 2) do
      [mod_str] ->
        with {:ok, mods} <- parse_modifier(mod_str), do: {:ok, mods, :press}

      [mod_str, ev_str] ->
        with {:ok, mods} <- parse_modifier(mod_str),
             {:ok, event_type} <- parse_kitty_event_type(ev_str) do
          {:ok, mods, event_type}
        end
    end
  end

  defp parse_kitty_event_type("1"), do: {:ok, :press}
  defp parse_kitty_event_type("2"), do: {:ok, :repeat}
  defp parse_kitty_event_type("3"), do: {:ok, :release}
  defp parse_kitty_event_type(_), do: :error

  defp kitty_event_tuple(:press, key, mods), do: {:key, key, mods}
  defp kitty_event_tuple(:repeat, key, mods), do: {:key_repeat, key, mods}
  defp kitty_event_tuple(:release, key, mods), do: {:key_release, key, mods}

  # Kitty private-range functional-key codepoints.
  defp kitty_key(57_344), do: :escape
  defp kitty_key(57_345), do: :enter
  defp kitty_key(57_346), do: :tab
  defp kitty_key(57_347), do: :backspace
  defp kitty_key(57_348), do: :insert
  defp kitty_key(57_349), do: :delete
  defp kitty_key(57_350), do: :left
  defp kitty_key(57_351), do: :right
  defp kitty_key(57_352), do: :up
  defp kitty_key(57_353), do: :down
  defp kitty_key(57_354), do: :page_up
  defp kitty_key(57_355), do: :page_down
  defp kitty_key(57_356), do: :home
  defp kitty_key(57_357), do: :end
  defp kitty_key(n) when n in 57_364..57_375, do: {:f, n - 57_363}
  defp kitty_key(n), do: {:char, n}

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
