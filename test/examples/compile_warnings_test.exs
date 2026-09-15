defmodule Harlock.Examples.CompileWarningsTest do
  # async: false — compiling an example redefines its module, which other
  # example tests may be using at the same time.
  use ExUnit.Case, async: false

  # The examples are scripts, so `mix compile --warnings-as-errors` never sees
  # them, and loading one in a test prints its warnings without failing
  # anything. A warning in an example is shown to whoever runs it.
  for path <- Path.wildcard(Path.join([__DIR__, "..", "..", "examples", "*.exs"])) do
    name = Path.basename(path)

    test "#{name} compiles without warnings" do
      path = unquote(path)

      {_result, diagnostics} = Code.with_diagnostics(fn -> Code.compile_file(path) end)

      warnings =
        for %{severity: :warning, message: message} <- diagnostics,
            # Compiling it again in the same VM is this test's doing, not the
            # example's.
            not String.starts_with?(message, "redefining module"),
            do: message

      assert warnings == [], "#{unquote(name)}:\n" <> Enum.join(warnings, "\n")
    end
  end
end
