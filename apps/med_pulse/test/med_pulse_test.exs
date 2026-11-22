defmodule MedPulseTest do
  use ExUnit.Case, async: true

  alias MedCore.Session
  alias MedPulse.ClinicalProfile
  alias MedRTC.SessionServer
  alias MedWeb.Signaling

  test "standalone reference flow proves preview drop, recording continuity, and duplicate completion without encounter_ref" do
    assert MedPulse.profile() == ClinicalProfile
    assert ClinicalProfile.topology() == :server_terminated

    session = Session.new(id: "pulse_demo_1", streams: ClinicalProfile.streams())
    {:ok, pid} = SessionServer.start_link(session: session, subscribers: [self()])

    SessionServer.dispatch(
      pid,
      Signaling.to_session_event({:join, "doc_1", "c1", :clinician, 100})
    )

    SessionServer.dispatch(
      pid,
      {:acquisition_started, %{acquisition_id: "acq_1", stream_id: "auscultation", t_ms: 200}}
    )

    SessionServer.dispatch(pid, Signaling.to_session_event({:leave, "doc_1", "c1", 500}))

    complete =
      {:capture_completed,
       %{
         acquisition_id: "acq_1",
         artifact_sha256: "sha_pulse_1",
         interval_ms: {200, 1_200},
         continuity: :observed_continuous,
         delivery_id: "d1",
         t_ms: 1_250
       }}

    SessionServer.dispatch(pid, complete)

    SessionServer.dispatch(
      pid,
      Signaling.to_session_event({:join, "doc_1", "c2", :clinician, 1_400})
    )

    SessionServer.dispatch(
      pid,
      put_elem(complete, 1, %{elem(complete, 1) | delivery_id: "d2", t_ms: 1_500})
    )

    snap = SessionServer.snapshot(pid)
    assert snap.encounter_ref == nil
    assert length(snap.preview_interruptions) == 1
    assert hd(snap.preview_interruptions).ended_at_ms == 1_400

    assert snap.integrity_reports[{:recording_artifact, "acq_1"}].continuity ==
             :observed_continuous
  end
end
