defmodule MedWebTest do
  use ExUnit.Case, async: true

  alias MedWeb.Signaling

  test "normalizes browser signaling events and ships RTCPeerConnection hook asset in source and Welded modes" do
    assert {:peer_connected, %{peer_id: "p1", connection_id: "c1", role: :clinician, t_ms: 10}} ==
             Signaling.to_session_event({:join, "p1", "c1", :clinician, 10})

    assert {:peer_disconnected, %{peer_id: "p1", connection_id: "c1", t_ms: 20}} ==
             Signaling.to_session_event({:leave, "p1", "c1", 20})

    hook_path = Signaling.hook_asset_full_path()
    assert File.regular?(hook_path)
    assert String.contains?(File.read!(hook_path), "RTCPeerConnection")
  end
end
