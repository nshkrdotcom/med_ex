defmodule MedPulseTest do
  use ExUnit.Case, async: true

  alias MedCore.Session
  alias MedPulse.ClinicalProfile
  alias MedRTC.SessionServer
  alias MedRTC.WavCapture
  alias MedWeb.Signaling

  test "standalone reference flow proves preview drop, recording continuity, and duplicate completion without encounter_ref" do
    assert MedPulse.profile() == ClinicalProfile
    assert ClinicalProfile.topology() == :server_terminated

    wav_path = Path.expand("../../../fixtures/circor/2530_AV.wav", __DIR__)

    wav_bytes =
      if File.regular?(wav_path) do
        File.read!(wav_path)
      else
        pcm = for i <- 0..3_999, into: <<>>, do: <<rem(i * 19, 2500)::little-signed-16>>
        WavCapture.encode_pcm16_wav(pcm, 4_000)
      end

    {:ok, wav} = WavCapture.parse_wav(wav_bytes)

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

    summary =
      WavCapture.replay(wav,
        acquisition_id: "acq_1",
        started_at_ms: 200,
        on_preview_chunk: fn idx, _chunk ->
          if idx == 10 do
            SessionServer.dispatch(pid, Signaling.to_session_event({:leave, "doc_1", "c1", 500}))
          end

          if idx in 10..19, do: {:error, :preview_disconnected}, else: :ok
        end
      )

    complete =
      {:capture_completed,
       %{
         acquisition_id: "acq_1",
         artifact_sha256: summary.artifact_sha256,
         interval_ms: summary.interval_ms,
         continuity: summary.continuity,
         delivery_id: "d1",
         t_ms: elem(summary.interval_ms, 1) + 50
       }}

    SessionServer.dispatch(pid, complete)

    SessionServer.dispatch(
      pid,
      Signaling.to_session_event(
        {:join, "doc_1", "c2", :clinician, elem(summary.interval_ms, 1) + 100}
      )
    )

    SessionServer.dispatch(
      pid,
      put_elem(complete, 1, %{
        elem(complete, 1)
        | delivery_id: "d2",
          t_ms: elem(summary.interval_ms, 1) + 200
      })
    )

    snap = SessionServer.snapshot(pid)
    assert snap.encounter_ref == nil
    assert length(snap.preview_interruptions) == 1
    assert hd(snap.preview_interruptions).ended_at_ms == elem(summary.interval_ms, 1) + 100
    assert summary.preview_chunks_dropped == 10
    assert summary.sample_count == wav.sample_count

    assert snap.integrity_reports[{:recording_artifact, "acq_1"}].continuity ==
             :observed_continuous
  end
end
