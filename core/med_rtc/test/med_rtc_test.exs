defmodule MedRTCTest do
  use ExUnit.Case, async: true

  alias MedCore.Session
  alias MedCore.StreamSpec
  alias MedRTC.SessionServer

  test "SessionServer preserves active capture across preview disconnect and delivers facts to subscribers" do
    assert MedRTC.core_version() == "0.1.0"

    stream = %StreamSpec{
      id: "sim_audio",
      archetype: :diagnostic_audio,
      modality: :stethoscope,
      codec_profile: {:pcm_s16le, 4_000},
      priority: 2,
      integrity_policy: %{
        require_dsp_disabled: true,
        max_packet_loss_pct: 0.05,
        max_jitter_ms: 40,
        allow_plc: false,
        sample_rate_hz: 4_000
      }
    }

    session = Session.new(id: "live_1", encounter_ref: "enc_live", streams: [stream])
    {:ok, pid} = SessionServer.start_link(session: session, subscribers: [self()])

    SessionServer.dispatch(
      pid,
      {:peer_connected, %{peer_id: "clin_1", connection_id: "c1", role: :clinician, t_ms: 100}}
    )

    SessionServer.dispatch(
      pid,
      {:acquisition_started, %{acquisition_id: "acq_live", stream_id: "sim_audio", t_ms: 200}}
    )

    SessionServer.dispatch(
      pid,
      {:peer_disconnected, %{peer_id: "clin_1", connection_id: "c1", t_ms: 300}}
    )

    SessionServer.dispatch(
      pid,
      {:capture_completed,
       %{
         acquisition_id: "acq_live",
         artifact_sha256: "digest_live",
         interval_ms: {200, 1_200},
         continuity: :observed_continuous,
         delivery_id: "d1",
         t_ms: 1_250
       }}
    )

    assert_received {:med_rtc_effect, "live_1",
                     {:emit_fact, :capture_completed,
                      %{acquisition_id: "acq_live", artifact_sha256: "digest_live"}}}

    snap = SessionServer.snapshot(pid)

    assert snap.integrity_reports[{:recording_artifact, "acq_live"}].continuity ==
             :observed_continuous
  end
end
