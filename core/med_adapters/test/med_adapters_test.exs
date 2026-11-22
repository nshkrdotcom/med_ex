defmodule MedAdaptersTest do
  use ExUnit.Case, async: true

  test "skeleton links against MedCore" do
    assert MedAdapters.core_version() == "0.1.0"
  end
end
