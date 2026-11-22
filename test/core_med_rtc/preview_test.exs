defmodule MedRTC.PreviewTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription
  alias MedRTC.Preview
  alias MedRTC.WavCapture

  test "a receive-only peer receives an Opus RTP payload" do
    {:ok, receiver} = PeerConnection.start_link(ice_servers: [])
    on_exit(fn -> stop(receiver) end)
    {:ok, _} = PeerConnection.add_transceiver(receiver, :audio, direction: :recvonly)
    {:ok, offer} = PeerConnection.create_offer(receiver)
    :ok = PeerConnection.set_local_description(receiver, offer)
    assert_receive {:ex_webrtc, ^receiver, {:ice_gathering_state_change, :complete}}, 5_000

    assert {:ok, preview, answer} =
             Preview.answer(PeerConnection.get_local_description(receiver).sdp)

    on_exit(fn -> Preview.close(preview) end)

    :ok =
      PeerConnection.set_remote_description(receiver, %SessionDescription{
        type: :answer,
        sdp: answer
      })

    assert_receive {:ex_webrtc, ^receiver, {:connection_state_change, :connected}}, 5_000

    assert_receive {:ex_webrtc, sender, {:connection_state_change, :connected}}
                   when sender == preview.pid,
                   5_000

    silence = <<0xF8, 0xFF, 0xFE>>

    for index <- 12..17 do
      :ok = Preview.send_opus(preview, silence, index)
      Process.sleep(20)
    end

    assert_receive {:ex_webrtc, ^receiver, {:rtp, _track_id, nil, %{payload: ^silence}}}, 2_000
  end

  @tag :tmp_dir
  test "a blocked preview cannot delay finalization of the original PCM artifact", %{tmp_dir: dir} do
    pcm = :binary.copy(<<0, 0>>, 320)
    wav_path = Path.join(dir, "input.wav")
    preview_path = Path.join(dir, "input.opus")
    artifact_path = Path.join(dir, "recording.wav")
    File.write!(wav_path, WavCapture.encode_pcm16_wav(pcm, 4_000))

    {:ok, writer} = ExWebRTC.Media.Ogg.Writer.open(preview_path)

    writer =
      Enum.reduce(1..4, writer, fn _, writer ->
        {:ok, writer} = ExWebRTC.Media.Ogg.Writer.write_packet(writer, <<0xF8, 0xFF, 0xFE>>)
        writer
      end)

    :ok = ExWebRTC.Media.Ogg.Writer.close(writer)
    test_pid = self()

    task =
      Task.async(fn ->
        WavCapture.record(wav_path, preview_path, artifact_path,
          acquisition_id: "capture",
          on_preview_frame: fn _, _ ->
            send(test_pid, :preview_entered)
            Process.sleep(:infinity)
          end
        )
      end)

    assert_receive :preview_entered, 2_000

    assert {:ok, %{sample_count: 320, duration_ms: 80, continuity: :observed_continuous}} =
             Task.await(task, 500)

    assert {:ok, %{pcm: ^pcm}} = artifact_path |> File.read!() |> WavCapture.parse_wav()
  end

  test "truncated and partial-frame WAV input is rejected" do
    audio = WavCapture.encode_pcm16_wav(<<1, 2, 3, 4>>, 4_000)
    assert {:error, :invalid_wav_header} = WavCapture.parse_wav(binary_part(audio, 0, 47))

    <<prefix::binary-size(4), _size::little-32, body::binary-size(32), _length::little-32,
      data::binary>> = audio

    partial = <<prefix::binary, 40::little-32, body::binary, 3::little-32, data::binary>>
    assert {:error, :invalid_pcm_frames} = WavCapture.parse_wav(partial)
  end

  defp stop(pid) do
    if Process.alive?(pid), do: PeerConnection.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
