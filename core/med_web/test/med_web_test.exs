defmodule MedWebTest do
  use ExUnit.Case, async: true

  test "skeleton links against MedRTC and MedCore" do
    assert MedWeb.runtime_core_version() == "0.1.0"
  end
end
