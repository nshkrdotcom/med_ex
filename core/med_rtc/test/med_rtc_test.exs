defmodule MedRTCTest do
  use ExUnit.Case, async: true

  alias MedCore.Session
  alias MedCore.StreamSpec
  alias MedRTC.PeerLoopback
  alias MedRTC.SessionServer

  test "real ExWebRTC SDP/ICE loopback survives preview disconnect/rejoin while simulated capture completes" do
    assert MedRTC.core_version() == "0.1.0"

    stream = %StreamSpec{
      id: "sim_audio",
      archetype: :diagnostic_audio,
      modality: :stethoscope,
      codec_profile: {:opus, bitrate: 32_000, fec: true},
      priority: 2,
      integrity_policy: %{
        require_dsp_disabled: false,
        max_packet_loss_pct: 1.0,
        max_jitter_ms: 80,
        allow_plc: true,
        sample_rate_hz: 48_000
      }
    }

    session = Session.new(id: "live_rtc_1", encounter_ref: "enc_live", streams: [stream])
    {:ok, server} = SessionServer.start_link(session: session, subscribers: [self()])

    # 1. Establish real ExWebRTC SDP/ICE peer connection #1
    {:ok, pair_a} = PeerLoopback.connect_pair("conn_a")
    assert String.contains?(pair_a.offer_sdp, "m=audio")
    assert String.contains?(pair_a.answer_sdp, "m=audio")

    SessionServer.dispatch(
      server,
      {:peer_connected,
       %{peer_id: "clin_1", connection_id: "conn_a", role: :clinician, t_ms: 100}}
    )

    # 2. Start deterministic simulated capture
    SessionServer.dispatch(
      server,
      {:acquisition_started, %{acquisition_id: "acq_live", stream_id: "sim_audio", t_ms: 200}}
    )

    # 3. Drop real ExWebRTC preview connection #1 while capture continues
    :ok = PeerLoopback.close_pair(pair_a)

    SessionServer.dispatch(
      server,
      {:peer_disconnected, %{peer_id: "clin_1", connection_id: "conn_a", t_ms: 300}}
    )

    # 4. Simulated capture finishes independently
    SessionServer.dispatch(
      server,
      {:capture_completed,
       %{
         acquisition_id: "acq_live",
         artifact_sha256: "digest_live_rtc",
         interval_ms: {200, 1_200},
         continuity: :observed_continuous,
         delivery_id: "d1",
         t_ms: 1_250
       }}
    )

    # 5. Re-establish a brand-new real ExWebRTC peer connection #2 to the SAME session
    {:ok, pair_b} = PeerLoopback.connect_pair("conn_b")

    SessionServer.dispatch(
      server,
      {:peer_connected,
       %{peer_id: "clin_1", connection_id: "conn_b", role: :clinician, t_ms: 1_400}}
    )

    :ok = PeerLoopback.close_pair(pair_b)

    assert_received {:med_rtc_effect, "live_rtc_1",
                     {:emit_fact, :capture_completed,
                      %{acquisition_id: "acq_live", artifact_sha256: "digest_live_rtc"}}}

    snap = SessionServer.snapshot(server)
    assert snap.connections["conn_a"].state == :disconnected
    assert snap.connections["conn_b"].state == :connected
    assert [%{started_at_ms: 300, ended_at_ms: 1_400}] = snap.preview_interruptions

    assert snap.integrity_reports[{:recording_artifact, "acq_live"}].continuity ==
             :observed_continuous
  end
end
