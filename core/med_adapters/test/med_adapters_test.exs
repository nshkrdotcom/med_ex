defmodule MedAdaptersTest do
  use ExUnit.Case, async: true

  test "exposes MedAdapters.Inference advisory callback behaviour" do
    assert {:infer, 2} in MedAdapters.Inference.behaviour_info(:callbacks)
  end
end
