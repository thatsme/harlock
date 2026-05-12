defmodule Harlock.Render.StyleTableTest do
  use ExUnit.Case, async: true

  alias Harlock.Render.{Style, StyleTable}

  test "default style is at id 0" do
    table = StyleTable.new()
    assert StyleTable.default_id() == 0
    assert StyleTable.get(table, 0) == %Style{}
  end

  test "interning default style returns id 0 without growing" do
    table = StyleTable.new()
    {id, table2} = StyleTable.intern(table, %Style{})
    assert id == 0
    assert table2 == table
  end

  test "first new style gets id 1, second gets id 2" do
    table = StyleTable.new()
    {id1, table} = StyleTable.intern(table, %Style{bold: true})
    {id2, table} = StyleTable.intern(table, %Style{italic: true})
    assert id1 == 1
    assert id2 == 2
    assert StyleTable.get(table, id1) == %Style{bold: true}
    assert StyleTable.get(table, id2) == %Style{italic: true}
  end

  test "interning the same style twice returns the same id" do
    table = StyleTable.new()
    {id1, table} = StyleTable.intern(table, %Style{fg: :red})
    {id2, _table} = StyleTable.intern(table, %Style{fg: :red})
    assert id1 == id2
  end
end
