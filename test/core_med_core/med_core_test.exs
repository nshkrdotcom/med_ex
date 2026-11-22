defmodule MedCoreTest do
  use ExUnit.Case, async: true

  alias MedCore.Session

  test "skeleton compiles and exposes standalone Session struct" do
    assert MedCore.version() == "0.1.0"

    session = %Session{
      id: "sess_1",
      topology: :server_terminated,
      streams: %{}
    }

    assert session.encounter_ref == nil
    assert session.connections == %{}
    assert session.acquisitions == %{}
    assert session.degradation_level == :nominal
  end
end
