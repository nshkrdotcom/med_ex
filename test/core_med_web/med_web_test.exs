defmodule MedWebTest do
  use ExUnit.Case, async: true

  alias MedWeb.Signaling

  test "links against MedRTC/MedCore and ships browser hook asset in both source and Welded modes" do
    assert MedWeb.runtime_core_version() == "0.1.0"

    assert {:peer_connected, %{peer_id: "p1", connection_id: "c1", role: :clinician, t_ms: 10}} ==
             Signaling.to_session_event({:join, "p1", "c1", :clinician, 10})

    assert File.regular?(Signaling.hook_asset_full_path())
  end
end
