defmodule Harlock.Terminal.Input.ParserTest do
  use ExUnit.Case, async: true

  alias Harlock.Terminal.Input.Parser

  defp feed(bytes), do: Parser.feed(Parser.new(), bytes)
  defp events(bytes), do: feed(bytes) |> elem(0)

  describe "ascii" do
    test "printable chars become {:char, codepoint}" do
      assert events("ab") == [
               {:key, {:char, ?a}, []},
               {:key, {:char, ?b}, []}
             ]
    end

    test "Enter, Tab, Backspace, DEL" do
      assert events("\r") == [{:key, :enter, []}]
      assert events("\n") == [{:key, :enter, []}]
      assert events("\t") == [{:key, :tab, []}]
      assert events(<<0x7F>>) == [{:key, :backspace, []}]
      assert events(<<0x08>>) == [{:key, :backspace, []}]
    end

    test "Ctrl-letter" do
      # Ctrl-a = 0x01
      assert events(<<0x01>>) == [{:key, {:char, ?a}, [:ctrl]}]
      assert events(<<0x03>>) == [{:key, {:char, ?c}, [:ctrl]}]
      # 0x08/0x09/0x0A/0x0D are not classified as Ctrl-letters; they're keys.
      # Ctrl-l = 0x0C
      assert events(<<0x0C>>) == [{:key, {:char, ?l}, [:ctrl]}]
    end
  end

  describe "CSI arrows and navigation" do
    test "arrows" do
      assert events("\e[A") == [{:key, :up, []}]
      assert events("\e[B") == [{:key, :down, []}]
      assert events("\e[C") == [{:key, :right, []}]
      assert events("\e[D") == [{:key, :left, []}]
    end

    test "home/end variants" do
      assert events("\e[H") == [{:key, :home, []}]
      assert events("\e[F") == [{:key, :end, []}]
      assert events("\e[1~") == [{:key, :home, []}]
      assert events("\e[4~") == [{:key, :end, []}]
      assert events("\e[7~") == [{:key, :home, []}]
      assert events("\e[8~") == [{:key, :end, []}]
    end

    test "insert/delete/page" do
      assert events("\e[2~") == [{:key, :insert, []}]
      assert events("\e[3~") == [{:key, :delete, []}]
      assert events("\e[5~") == [{:key, :page_up, []}]
      assert events("\e[6~") == [{:key, :page_down, []}]
    end

    test "shift-tab" do
      assert events("\e[Z") == [{:key, :tab, [:shift]}]
    end

    test "function keys F1-F12 (CSI form)" do
      assert events("\e[11~") == [{:key, {:f, 1}, []}]
      assert events("\e[15~") == [{:key, {:f, 5}, []}]
      assert events("\e[24~") == [{:key, {:f, 12}, []}]
    end

    test "focus reporting" do
      assert events("\e[I") == [{:focus, :in}]
      assert events("\e[O") == [{:focus, :out}]
    end

    test "unknown CSI is reported, not crashed on" do
      assert events("\e[99X") == [{:unknown_csi, "99", ?X}]
    end
  end

  describe "modified arrows / nav (CSI 1;mod<letter>)" do
    test "shift modifier (mod=2)" do
      assert events("\e[1;2A") == [{:key, :up, [:shift]}]
      assert events("\e[1;2B") == [{:key, :down, [:shift]}]
      assert events("\e[1;2C") == [{:key, :right, [:shift]}]
      assert events("\e[1;2D") == [{:key, :left, [:shift]}]
      assert events("\e[1;2H") == [{:key, :home, [:shift]}]
      assert events("\e[1;2F") == [{:key, :end, [:shift]}]
    end

    test "alt modifier (mod=3)" do
      assert events("\e[1;3A") == [{:key, :up, [:alt]}]
      assert events("\e[1;3D") == [{:key, :left, [:alt]}]
    end

    test "ctrl modifier (mod=5)" do
      assert events("\e[1;5A") == [{:key, :up, [:ctrl]}]
      assert events("\e[1;5C") == [{:key, :right, [:ctrl]}]
      assert events("\e[1;5D") == [{:key, :left, [:ctrl]}]
    end

    test "combined modifiers" do
      # shift+alt (mod=4)
      assert events("\e[1;4A") == [{:key, :up, [:shift, :alt]}]
      # shift+ctrl (mod=6)
      assert events("\e[1;6C") == [{:key, :right, [:shift, :ctrl]}]
      # alt+ctrl (mod=7)
      assert events("\e[1;7D") == [{:key, :left, [:alt, :ctrl]}]
      # shift+alt+ctrl (mod=8)
      assert events("\e[1;8B") == [{:key, :down, [:shift, :alt, :ctrl]}]
    end

    test "meta modifier (mod=9 → bits=8)" do
      assert events("\e[1;9A") == [{:key, :up, [:meta]}]
      # shift+meta (mod=10 → bits=9)
      assert events("\e[1;10A") == [{:key, :up, [:shift, :meta]}]
      # shift+alt+ctrl+meta (mod=16 → bits=15)
      assert events("\e[1;16A") == [{:key, :up, [:shift, :alt, :ctrl, :meta]}]
    end

    test "mod=1 means no modifiers (per spec)" do
      assert events("\e[1;1A") == [{:key, :up, []}]
    end

    test "out-of-range modifier reported as unknown_csi" do
      assert events("\e[1;17A") == [{:unknown_csi, "1;17", ?A}]
      assert events("\e[1;A") == [{:unknown_csi, "1;", ?A}]
    end
  end

  describe "SGR mouse" do
    test "left press / release at (col, row)" do
      assert events("\e[<0;10;5M") == [{:mouse, :press, :left, 10, 5, []}]
      assert events("\e[<0;10;5m") == [{:mouse, :release, :left, 10, 5, []}]
    end

    test "middle / right buttons" do
      assert events("\e[<1;1;1M") == [{:mouse, :press, :middle, 1, 1, []}]
      assert events("\e[<2;80;24M") == [{:mouse, :press, :right, 80, 24, []}]
    end

    test "drag (motion + button held)" do
      # b = 0 (left) | 32 (motion) = 32
      assert events("\e[<32;15;8M") == [{:mouse, :drag, :left, 15, 8, []}]
      # b = 2 (right) | 32 = 34
      assert events("\e[<34;15;8M") == [{:mouse, :drag, :right, 15, 8, []}]
    end

    test "pure motion (no button)" do
      # b = 3 (no button) | 32 (motion) = 35
      assert events("\e[<35;20;10M") == [{:mouse, :move, nil, 20, 10, []}]
    end

    test "wheel up / down" do
      # b = 64 (wheel + index 0)
      assert events("\e[<64;1;1M") == [{:mouse, :wheel_up, nil, 1, 1, []}]
      # b = 65 (wheel + index 1)
      assert events("\e[<65;1;1M") == [{:mouse, :wheel_down, nil, 1, 1, []}]
    end

    test "extra buttons (4/5)" do
      # b = 128 (extra) | 0 = 128
      assert events("\e[<128;1;1M") == [{:mouse, :press, :extra4, 1, 1, []}]
      # b = 128 | 1 = 129
      assert events("\e[<129;1;1M") == [{:mouse, :press, :extra5, 1, 1, []}]
    end

    test "modifiers (shift / alt / ctrl)" do
      # b = 0 | 4 (shift) = 4
      assert events("\e[<4;1;1M") == [{:mouse, :press, :left, 1, 1, [:shift]}]
      # b = 0 | 8 (alt) = 8
      assert events("\e[<8;1;1M") == [{:mouse, :press, :left, 1, 1, [:alt]}]
      # b = 0 | 16 (ctrl) = 16
      assert events("\e[<16;1;1M") == [{:mouse, :press, :left, 1, 1, [:ctrl]}]
      # b = 0 | 4 | 8 | 16 = 28 (shift+alt+ctrl)
      assert events("\e[<28;1;1M") == [
               {:mouse, :press, :left, 1, 1, [:shift, :alt, :ctrl]}
             ]
    end

    test "wheel with ctrl modifier" do
      # b = 64 (wheel up) | 16 (ctrl) = 80
      assert events("\e[<80;5;5M") == [{:mouse, :wheel_up, nil, 5, 5, [:ctrl]}]
    end

    test "malformed mouse params → unknown_csi" do
      assert events("\e[<0;10M") == [{:unknown_csi, "<0;10", ?M}]
      assert events("\e[<;1;1M") == [{:unknown_csi, "<;1;1", ?M}]
      assert events("\e[<0;0;0M") == [{:unknown_csi, "<0;0;0", ?M}]
    end
  end

  describe "kitty keyboard protocol" do
    test "detection response: CSI ? <flags> u → capability event" do
      assert events("\e[?1u") == [{:capability, :kitty_keyboard, 1}]
      assert events("\e[?15u") == [{:capability, :kitty_keyboard, 15}]
      assert events("\e[?0u") == [{:capability, :kitty_keyboard, 0}]
    end

    test "press of printable ASCII codepoint" do
      # 'a' = 97
      assert events("\e[97u") == [{:key, {:char, ?a}, []}]
      # 'A' = 65
      assert events("\e[65u") == [{:key, {:char, ?A}, []}]
    end

    test "press with modifier (CSI code;mod u)" do
      # ctrl-a (mod=5)
      assert events("\e[97;5u") == [{:key, {:char, ?a}, [:ctrl]}]
      # shift+alt 'b' (mod=4)
      assert events("\e[98;4u") == [{:key, {:char, ?b}, [:shift, :alt]}]
    end

    test "functional keys via private-range codepoints" do
      # 57344=Escape, 57352=Up, 57364=F1, 57375=F12
      assert events("\e[57344u") == [{:key, :escape, []}]
      assert events("\e[57346u") == [{:key, :tab, []}]
      assert events("\e[57352u") == [{:key, :up, []}]
      assert events("\e[57364u") == [{:key, {:f, 1}, []}]
      assert events("\e[57375u") == [{:key, {:f, 12}, []}]
    end

    test "press event type (explicit :1)" do
      assert events("\e[97;5:1u") == [{:key, {:char, ?a}, [:ctrl]}]
    end

    test "repeat event (event type 2) → :key_repeat tuple" do
      assert events("\e[97;1:2u") == [{:key_repeat, {:char, ?a}, []}]
      assert events("\e[57352;5:2u") == [{:key_repeat, :up, [:ctrl]}]
    end

    test "release event (event type 3) → :key_release tuple" do
      assert events("\e[97;1:3u") == [{:key_release, {:char, ?a}, []}]
      assert events("\e[57346;1:3u") == [{:key_release, :tab, []}]
    end

    test "alternate keys (<code>:<shifted>:<base>) — alternates are ignored" do
      # Shift-a where shifted form is 'A' (65); we take primary 97 = 'a'.
      assert events("\e[97:65;2u") == [{:key, {:char, ?a}, [:shift]}]
    end

    test "unknown event type → unknown_csi" do
      assert events("\e[97;1:9u") == [{:unknown_csi, "97;1:9", ?u}]
    end

    test "malformed kitty params → unknown_csi" do
      # Empty params with `u` final byte (e.g. xterm "restore cursor" echoed).
      assert events("\e[u") == [{:unknown_csi, "", ?u}]
      # Out-of-range event type.
      assert events("\e[97;1:99u") == [{:unknown_csi, "97;1:99", ?u}]
    end
  end

  describe "modified tilde keys (CSI n;mod~)" do
    test "shift-PageUp / shift-PageDown" do
      assert events("\e[5;2~") == [{:key, :page_up, [:shift]}]
      assert events("\e[6;2~") == [{:key, :page_down, [:shift]}]
    end

    test "ctrl-PageUp / ctrl-PageDown" do
      assert events("\e[5;5~") == [{:key, :page_up, [:ctrl]}]
      assert events("\e[6;5~") == [{:key, :page_down, [:ctrl]}]
    end

    test "ctrl-Delete / shift-Insert" do
      assert events("\e[3;5~") == [{:key, :delete, [:ctrl]}]
      assert events("\e[2;2~") == [{:key, :insert, [:shift]}]
    end

    test "modified F-keys" do
      # Shift-F5
      assert events("\e[15;2~") == [{:key, {:f, 5}, [:shift]}]
      # Ctrl-F12
      assert events("\e[24;5~") == [{:key, {:f, 12}, [:ctrl]}]
      # Shift+Ctrl+Alt F1
      assert events("\e[11;8~") == [{:key, {:f, 1}, [:shift, :alt, :ctrl]}]
    end

    test "unknown tilde code reported as unknown_csi" do
      assert events("\e[99;2~") == [{:unknown_csi, "99;2", ?~}]
    end

    test "malformed mod reported as unknown_csi" do
      assert events("\e[5;~") == [{:unknown_csi, "5;", ?~}]
      assert events("\e[5;99~") == [{:unknown_csi, "5;99", ?~}]
    end
  end

  describe "SS3 (application-mode arrows / F1-F4)" do
    test "arrows" do
      assert events("\eOA") == [{:key, :up, []}]
      assert events("\eOD") == [{:key, :left, []}]
    end

    test "F1-F4" do
      assert events("\eOP") == [{:key, {:f, 1}, []}]
      assert events("\eOS") == [{:key, {:f, 4}, []}]
    end
  end

  describe "ESC handling" do
    test "lone ESC at end of chunk → Escape" do
      assert events("\e") == [{:key, :escape, []}]
    end

    test "ESC + printable → Alt-prefixed key" do
      assert events("\ea") == [{:key, {:char, ?a}, [:alt]}]
      assert events("\eX") == [{:key, {:char, ?X}, [:alt]}]
    end
  end

  describe "bracketed paste" do
    test "complete paste in one chunk" do
      assert events("\e[200~hello\e[201~") == [{:paste, "hello"}]
    end

    test "paste with newlines and printable text around it" do
      assert events("a\e[200~line1\nline2\e[201~b") == [
               {:key, {:char, ?a}, []},
               {:paste, "line1\nline2"},
               {:key, {:char, ?b}, []}
             ]
    end

    test "split across feeds — paste held until end marker arrives" do
      parser = Parser.new()
      {events1, parser} = Parser.feed(parser, "\e[200~hel")
      assert events1 == []
      {events2, parser} = Parser.feed(parser, "lo\e[2")
      assert events2 == []
      {events3, _parser} = Parser.feed(parser, "01~done")

      assert events3 == [
               {:paste, "hello"},
               {:key, {:char, ?d}, []},
               {:key, {:char, ?o}, []},
               {:key, {:char, ?n}, []},
               {:key, {:char, ?e}, []}
             ]
    end
  end

  describe "partial sequences across feeds" do
    test "CSI split across feeds" do
      parser = Parser.new()
      {events1, parser} = Parser.feed(parser, "\e[")
      assert events1 == []
      {events2, _} = Parser.feed(parser, "A")
      assert events2 == [{:key, :up, []}]
    end

    test "UTF-8 multibyte split" do
      <<a, b>> = "ü"
      parser = Parser.new()
      {events1, parser} = Parser.feed(parser, <<a>>)
      assert events1 == []
      {events2, _} = Parser.feed(parser, <<b>>)
      assert events2 == [{:key, {:char, ?ü}, []}]
    end
  end

  describe "utf-8" do
    test "2-byte" do
      assert events("é") == [{:key, {:char, ?é}, []}]
    end

    test "3-byte" do
      assert events("中") == [{:key, {:char, ?中}, []}]
    end

    test "4-byte (emoji)" do
      assert events("🏴") == [{:key, {:char, 0x1F3F4}, []}]
    end
  end
end
