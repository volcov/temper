defmodule AlphaTest do
  use ExUnit.Case

  # Passes on even seeds, fails on odd ones — the integration suite
  # drives it with one seed of each parity to manufacture a flake.
  test "seed dependent" do
    assert rem(ExUnit.configuration()[:seed], 2) == 0
  end
end
