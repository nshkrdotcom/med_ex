defmodule MedRTCTest do
  use ExUnit.Case, async: true

  test "skeleton links against MedCore" do
    assert MedRTC.core_version() == "0.1.0"
  end
end
