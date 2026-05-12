defmodule Harlock.TestTest do
  use ExUnit.Case, async: true

  defmodule CounterApp do
    use Harlock.App

    def init(_), do: %{n: 0}

    def update({:key, {:char, ?+}, []}, m), do: %{m | n: m.n + 1}
    def update({:key, {:char, ?-}, []}, m), do: %{m | n: m.n - 1}
    def update({:key, {:char, ?q}, []}, _), do: :quit
    def update(_, m), do: m

    def view(m) do
      vbox(
        children: [
          text("Counter"),
          text("n=#{m.n}")
        ]
      )
    end
  end

  defmodule FocusApp do
    use Harlock.App

    def init(_), do: %{}

    def update(_, m), do: m

    def view(_) do
      vbox(
        children: [
          text("Email", focusable: :email),
          text("Name", focusable: :name),
          text("Submit", focusable: :submit)
        ]
      )
    end
  end

  describe "start_app + render" do
    test "renders initial state" do
      h = Harlock.Test.start_app(CounterApp, nil, rows: 5, cols: 20)
      output = Harlock.Test.render(h)

      assert output =~ "Counter"
      assert output =~ "n=0"

      Harlock.Test.stop(h)
    end
  end

  describe "send_key" do
    test "+ increments the counter" do
      h = Harlock.Test.start_app(CounterApp, nil, rows: 5, cols: 20)

      Harlock.Test.send_key(h, {:char, ?+})
      Harlock.Test.send_key(h, {:char, ?+})
      Harlock.Test.send_key(h, {:char, ?+})

      assert Harlock.Test.model(h).n == 3
      assert Harlock.Test.render(h) =~ "n=3"

      Harlock.Test.stop(h)
    end
  end

  describe "focus" do
    test "first focusable is focused initially" do
      h = Harlock.Test.start_app(FocusApp, nil, rows: 5, cols: 20)
      assert Harlock.Test.focused(h) == :email
      Harlock.Test.stop(h)
    end

    test "Tab cycles focus" do
      h = Harlock.Test.start_app(FocusApp, nil, rows: 5, cols: 20)

      assert Harlock.Test.focused(h) == :email

      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :name

      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :submit

      Harlock.Test.send_key(h, :tab)
      assert Harlock.Test.focused(h) == :email

      Harlock.Test.stop(h)
    end

    test "Shift-Tab cycles backwards" do
      h = Harlock.Test.start_app(FocusApp, nil, rows: 5, cols: 20)

      Harlock.Test.send_key(h, :tab, [:shift])
      assert Harlock.Test.focused(h) == :submit

      Harlock.Test.stop(h)
    end
  end
end
