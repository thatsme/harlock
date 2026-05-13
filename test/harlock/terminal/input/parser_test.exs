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

    test "out-of-range modifier reported as unknown_csi" do
      assert events("\e[1;1A") == [{:unknown_csi, "1;1", ?A}]
      assert events("\e[1;17A") == [{:unknown_csi, "1;17", ?A}]
      assert events("\e[1;A") == [{:unknown_csi, "1;", ?A}]
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
