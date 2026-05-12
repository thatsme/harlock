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
