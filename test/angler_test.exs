defmodule AnglerTest do
  use ExUnit.Case
  doctest Angler

  test "greets the world" do
    assert Angler.hello() == :world
  end
end
