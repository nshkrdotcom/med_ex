defmodule MedCoreTest do
  use ExUnit.Case, async: true

  test "skeleton compiles and exposes version" do
    assert MedCore.version() == "0.1.0"
  end
end
