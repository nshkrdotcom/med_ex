defmodule MedRTC.WavCaptureTest do
  use ExUnit.Case, async: true

  alias MedCore.Session
  alias MedCore.StreamSpec
  alias MedRTC.PeerLoopback
  alias MedRTC.SessionServer
  alias MedRTC.WavCapture

  @circor_path Path.expand("../../../fixtures/circor/2530_AV.wav", __DIR__)
  @circor_expected_pcm_sha256 "7c8c93ee4602072aa5c0e4c81a5a9e28d926b278f701218ea588bde9644efc66"

  test "one WAV input feeds independent live preview and lossless capture outputs across an ExWebRTC reconnect" do
    {wav_bin, expected_samples, expected_duration_ms, expected_sha} =
      if File.regular?(@circor_path) do
        {File.read!(@circor_path), 94_400, 23_600, @circor_expected_pcm_sha256}
      else
        pcm = for i <- 0..7_999, into: <<>>, do: <<rem(i * 17, 32_000)::little-signed-16>>
        sha = :crypto.hash(:sha256, pcm) |> Base.encode16(case: :lower)
        {WavCapture.encode_pcm16_wav(pcm, 4_000), 8_000, 2_000, sha}
      end

    {:ok, parsed} = WavCapture.parse_wav(wav_bin)
    assert parsed.sample_rate_hz == 4_000
    assert parsed.sample_count == expected_samples
    assert parsed.duration_ms == expected_duration_ms

    stream = %StreamSpec{
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

    session = Session.new(id: "wav_sess_1", streams: [stream])
    {:ok, server} = SessionServer.start_link(session: session)
    {:ok, pair_a} = PeerLoopback.connect_pair("conn_a")

    SessionServer.dispatch(
      server,
      {:peer_connected,
       %{peer_id: "clin_1", connection_id: "conn_a", role: :clinician, t_ms: 100}}
    )

    SessionServer.dispatch(
      server,
      {:acquisition_started, %{acquisition_id: "acq_wav", stream_id: "auscultation", t_ms: 200}}
    )

    # Drop live preview chunks 10..49 while lossless capture keeps recording every sample
    summary =
      WavCapture.replay(parsed,
        acquisition_id: "acq_wav",
        started_at_ms: 200,
        chunk_ms: 20,
        on_preview_chunk: fn idx, _chunk ->
          cond do
            idx == 10 ->
              :ok = PeerLoopback.close_pair(pair_a)

              SessionServer.dispatch(
                server,
                {:peer_disconnected, %{peer_id: "clin_1", connection_id: "conn_a", t_ms: 400}}
              )

              {:error, :preview_disconnected}

            idx > 10 and idx < 50 ->
              {:error, :preview_disconnected}

            true ->
              :ok
          end
        end
      )

    assert summary.preview_chunks_dropped == 40
    assert summary.preview_chunks_sent > 0
    assert summary.sample_count == expected_samples
    assert summary.duration_ms == expected_duration_ms
    assert summary.artifact_sha256 == expected_sha
    assert summary.continuity == :observed_continuous

    SessionServer.dispatch(
      server,
      {:capture_completed,
       %{
         acquisition_id: summary.acquisition_id,
         artifact_sha256: summary.artifact_sha256,
         interval_ms: summary.interval_ms,
         continuity: summary.continuity,
         delivery_id: "wav_deliv_1",
         t_ms: 24_000
       }}
    )

    {:ok, pair_b} = PeerLoopback.connect_pair("conn_b")

    SessionServer.dispatch(
      server,
      {:peer_connected,
       %{peer_id: "clin_1", connection_id: "conn_b", role: :clinician, t_ms: 24_100}}
    )

    :ok = PeerLoopback.close_pair(pair_b)

    snap = SessionServer.snapshot(server)
    assert [%{started_at_ms: 400, ended_at_ms: 24_100}] = snap.preview_interruptions

    assert snap.integrity_reports[{:recording_artifact, "acq_wav"}].continuity ==
             :observed_continuous
  end

  test "WavCapture reports :observed_gap when capture drops samples and :unknown when continuity is unobservable" do
    pcm = for i <- 0..799, into: <<>>, do: <<rem(i, 200)::little-signed-16>>
    {:ok, parsed} = pcm |> WavCapture.encode_pcm16_wav(4_000) |> WavCapture.parse_wav()

    gapped =
      WavCapture.replay(parsed,
        acquisition_id: "acq_gap",
        chunk_ms: 20,
        drop_capture_indices: [2]
      )

    assert gapped.continuity == :observed_gap
    assert gapped.sample_count < parsed.sample_count

    unobserved =
      WavCapture.replay(parsed,
        acquisition_id: "acq_unk",
        chunk_ms: 20,
        continuity_observable?: false
      )

    assert unobserved.continuity == :unknown
    assert unobserved.sample_count == parsed.sample_count
  end
end
