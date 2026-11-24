defmodule MedCoreTest do
  use ExUnit.Case, async: true

  alias MedCore.Session
  alias MedCore.StreamSpec

  defp sample_stream do
    %StreamSpec{
      id: "auscultation",
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
  end

  test "canonical reconnect trace keeps preview interruption and recording continuity independent and deduplicates redelivery" do
    s0 =
      Session.new(
        id: "s1",
        encounter_ref: "enc1",
        streams: [sample_stream()]
      )

    {s1, _} =
      Session.step(
        s0,
        {:peer_connected,
         %{peer_id: "clin_1", connection_id: "conn_a", role: :clinician, t_ms: 9_000}}
      )

    {s2, acq_effects} =
      Session.step(
        s1,
        {:acquisition_started, %{acquisition_id: "acq1", stream_id: "auscultation", t_ms: 10_000}}
      )

    assert {:start_lossless_capture, "auscultation", "acq1"} in acq_effects

    # Clinician loses live preview while capture continues
    {s3, drop_effects} =
      Session.step(
        s2,
        {:peer_disconnected, %{peer_id: "clin_1", connection_id: "conn_a", t_ms: 14_200}}
      )

    assert s3.integrity_reports[{:preview_stream, "auscultation"}].continuity == :unknown

    assert s3.acquisitions["acq1"].state == :active

    assert Enum.any?(drop_effects, fn
             {:emit_fact, :integrity_reported,
              %{subject: {:preview_stream, "auscultation"}, continuity: :unknown}} ->
               true

             _ ->
               false
           end)

    # Device finishes recording with observed continuity
    {s4, complete_effects} =
      Session.step(
        s3,
        {:capture_completed,
         %{
           acquisition_id: "acq1",
           artifact_sha256: "sha_ok_1",
           interval_ms: {10_000, 20_000},
           continuity: :observed_continuous,
           delivery_id: "deliv_1",
           t_ms: 20_050
         }}
      )

    assert s4.integrity_reports[{:recording_artifact, "acq1"}].continuity == :observed_continuous
    # Preview interruption remains distinct until reconnect
    assert s4.integrity_reports[{:preview_stream, "auscultation"}].continuity == :unknown

    assert Enum.any?(complete_effects, fn
             {:emit_fact, :capture_completed,
              %{
                encounter_ref: "enc1",
                session_id: "s1",
                acquisition_id: "acq1",
                artifact_sha256: "sha_ok_1",
                continuity: :observed_continuous
              }} ->
               true

             _ ->
               false
           end)

    # Browser rejoins the SAME session with a new connection_id
    {s5, rejoin_effects} =
      Session.step(
        s4,
        {:peer_connected,
         %{peer_id: "clin_1", connection_id: "conn_b", role: :clinician, t_ms: 21_000}}
      )

    assert Enum.any?(rejoin_effects, fn
             {:publish_ui, :session_snapshot,
              %{
                connection_id: "conn_b",
                preview_interruption: %{started_at_ms: 14_200, ended_at_ms: 21_000},
                completed_acquisitions: ["acq1"]
              }} ->
               true

             _ ->
               false
           end)

    # Duplicate capture_completed arrives with same digest -> idempotent no-op for consumers
    {s6, dup_effects} =
      Session.step(
        s5,
        {:capture_completed,
         %{
           acquisition_id: "acq1",
           artifact_sha256: "sha_ok_1",
           interval_ms: {10_000, 20_000},
           continuity: :observed_continuous,
           delivery_id: "deliv_2",
           t_ms: 21_300
         }}
      )

    refute Enum.any?(dup_effects, fn
             {:emit_fact, :capture_completed, _} -> true
             _ -> false
           end)

    assert Enum.any?(dup_effects, fn
             {:append_audit_log, %{action: :duplicate_capture_ignored}} -> true
             _ -> false
           end)

    assert s6.integrity_reports[{:recording_artifact, "acq1"}].continuity == :observed_continuous
  end

  test "recording continuity :unknown stays :unverified and is never coerced to :validated" do
    s0 = Session.new(id: "s_unk", streams: [sample_stream()])

    {s1, _} =
      Session.step(
        s0,
        {:acquisition_started, %{acquisition_id: "acq_u", stream_id: "auscultation", t_ms: 1_000}}
      )

    {s2, effects} =
      Session.step(
        s1,
        {:capture_completed,
         %{
           acquisition_id: "acq_u",
           artifact_sha256: "sha_unk",
           interval_ms: {1_000, 5_000},
           continuity: :unknown,
           delivery_id: "d1",
           t_ms: 5_050
         }}
      )

    assert s2.encounter_ref == nil
    assert s2.connections == %{}
    assert s2.integrity_reports[{:recording_artifact, "acq_u"}].continuity == :unknown

    assert Enum.any?(effects, fn
             {:emit_fact, :capture_completed, %{acquisition_id: "acq_u", continuity: :unknown}} ->
               true

             _ ->
               false
           end)
  end

  test "conflicting artifact_sha256 for the same acquisition emits :capture_conflict" do
    s0 = Session.new(id: "s_conf", encounter_ref: "enc_c", streams: [sample_stream()])

    {s1, _} =
      Session.step(
        s0,
        {:capture_completed,
         %{
           acquisition_id: "acq_c",
           artifact_sha256: "sha_first",
           interval_ms: {0, 4_000},
           continuity: :observed_continuous,
           delivery_id: "d1",
           t_ms: 4_010
         }}
      )

    {s2, conflict_effects} =
      Session.step(
        s1,
        {:capture_completed,
         %{
           acquisition_id: "acq_c",
           artifact_sha256: "sha_other",
           interval_ms: {0, 4_000},
           continuity: :observed_continuous,
           delivery_id: "d2",
           t_ms: 4_020
         }}
      )

    assert s2.acquisitions["acq_c"].state == :conflict

    {next, effects} =
      Session.step(
        s2,
        {:capture_completed,
         %{
           acquisition_id: "acq_c",
           artifact_sha256: "sha_first",
           interval_ms: {0, 4_000},
           continuity: :observed_continuous,
           delivery_id: "d3",
           t_ms: 4_030
         }}
      )

    assert next.acquisitions["acq_c"].state == :conflict
    refute Enum.any?(effects, &match?({:emit_fact, :capture_completed, _}, &1))

    assert Enum.any?(conflict_effects, fn
             {:emit_fact, :capture_conflict,
              %{existing_sha256: "sha_first", incoming_sha256: "sha_other"}} ->
               true

             _ ->
               false
           end)
  end

  test "a delayed disconnect cannot interrupt a replacement connection" do
    session = Session.new(id: "s", streams: [sample_stream()])
    join = %{peer_id: "peer", role: :clinician, connection_id: "old", t_ms: 1}
    {session, _} = Session.step(session, {:peer_connected, join})

    {session, _} =
      Session.step(session, {:peer_connected, %{join | connection_id: "new", t_ms: 2}})

    {next, effects} =
      Session.step(
        session,
        {:peer_disconnected, %{peer_id: "peer", connection_id: "old", t_ms: 3}}
      )

    assert next.connections["old"].state == :disconnected
    assert next.participants["peer"].active_connection_id == "new"
    assert next.preview_interruptions == []
    refute Enum.any?(effects, &match?({:emit_fact, :integrity_reported, _}, &1))
  end

  test "a repeated acquisition start cannot erase the first acquisition" do
    session = Session.new(id: "s1")
    event = {:acquisition_started, %{acquisition_id: "a1", stream_id: "preview", t_ms: 20}}
    {active, _effects} = Session.step(session, event)
    assert {^active, []} = Session.step(active, event)

    {completed, _effects} =
      Session.step(
        active,
        {:capture_completed,
         %{
           acquisition_id: "a1",
           artifact_sha256: "digest",
           interval_ms: {20, 40},
           continuity: :observed_continuous,
           delivery_id: "1",
           t_ms: 40
         }}
      )

    assert {^completed, []} = Session.step(completed, event)
  end
end
