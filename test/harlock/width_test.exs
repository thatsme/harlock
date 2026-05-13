defmodule Harlock.WidthTest do
  use ExUnit.Case, async: true

  alias Harlock.Width

  describe "width/1" do
    test "ASCII characters are 1 cell" do
      assert Width.width("a") == 1
      assert Width.width(" ") == 1
      assert Width.width("Z") == 1
      assert Width.width("9") == 1
    end

    test "empty string is 0" do
      assert Width.width("") == 0
    end

    test "control characters are 0" do
      # Note: <<0x07>> (BEL) is 1 byte; we measure as a grapheme.
      assert Width.width(<<0x07>>) == 0
      assert Width.width(<<0x1B>>) == 0
    end

    test "Latin combining marks (NFD) yield a 1-cell base" do
      # "é" in NFD form is U+0065 + U+0301 — base + combining acute.
      nfd = :unicode.characters_to_nfd_binary("é")
      assert Width.width(nfd) == 1
    end

    test "Latin precomposed (NFC) is 1 cell" do
      assert Width.width("é") == 1
    end

    test "CJK wide characters are 2 cells" do
      assert Width.width("東") == 2
      assert Width.width("京") == 2
      assert Width.width("漢") == 2
      assert Width.width("中") == 2
    end

    test "Hangul syllables are 2 cells" do
      assert Width.width("한") == 2
      assert Width.width("국") == 2
    end

    test "Fullwidth Latin is 2 cells" do
      assert Width.width("Ａ") == 2
      assert Width.width("ｂ") == 2
    end

    test "emoji are 2 cells" do
      assert Width.width("😀") == 2
      assert Width.width("🌍") == 2
      assert Width.width("🚀") == 2
    end

    test "regional indicator pair (flag) is 2 cells" do
      assert Width.width("🇮🇹") == 2
      assert Width.width("🇯🇵") == 2
      assert Width.width("🇺🇸") == 2
    end

    test "ZWJ family emoji is 2 cells" do
      assert Width.width("👨‍👩‍👧") == 2
    end

    test "variation selectors are zero on their own" do
      assert Width.width(<<0xFE0F::utf8>>) == 0
    end
  end

  describe "string_width/1" do
    test "ASCII strings" do
      assert Width.string_width("") == 0
      assert Width.string_width("hello") == 5
      assert Width.string_width("Harlock") == 7
    end

    test "mixed ASCII and CJK" do
      assert Width.string_width("hello東京") == 9
      assert Width.string_width("a中b") == 4
    end

    test "NFC and NFD agree" do
      nfc = "héllo"
      nfd = :unicode.characters_to_nfd_binary("héllo")
      assert Width.string_width(nfc) == 5
      assert Width.string_width(nfd) == 5
    end

    test "emoji sequences" do
      assert Width.string_width("🇮🇹🇯🇵") == 4
      assert Width.string_width("👨‍👩‍👧 family") == 9
    end
  end

  describe "slice/2" do
    test "ASCII truncation" do
      assert Width.slice("hello", 3) == "hel"
      assert Width.slice("hello", 10) == "hello"
      assert Width.slice("hello", 0) == ""
    end

    test "wide-grapheme truncation doesn't split a wide char" do
      assert Width.slice("東京abc", 5) == "東京a"
      # 5 cols: 東 (2) + 京 (2) + a (1) = 5
      assert Width.slice("東京abc", 4) == "東京"
      # 4 cols: 東 (2) + 京 (2) = 4
      assert Width.slice("東京abc", 3) == "東"
      # 3 cols: 東 (2) fits, 京 (2 more) doesn't — drop
    end

    test "wide first character doesn't fit at all" do
      assert Width.slice("東京", 1) == ""
    end
  end

  describe "pad_trailing/3" do
    test "pads with spaces to target width" do
      assert Width.pad_trailing("hi", 5) == "hi   "
      assert Width.pad_trailing("hello", 5) == "hello"
      assert Width.pad_trailing("toolong", 3) == "toolong"
    end

    test "respects column width for CJK" do
      # "東" is 2 cells; padding to 5 should add 3 spaces.
      assert Width.pad_trailing("東", 5) == "東   "
    end
  end

  describe "pad_leading/3" do
    test "pads on the left" do
      assert Width.pad_leading("hi", 5) == "   hi"
    end

    test "respects column width for CJK" do
      assert Width.pad_leading("東", 5) == "   東"
    end
  end
end
