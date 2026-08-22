defmodule TemperTest do
  use ExUnit.Case
  doctest Temper

  test "greets the world" do
    assert Temper.hello() == :world
  end
end
