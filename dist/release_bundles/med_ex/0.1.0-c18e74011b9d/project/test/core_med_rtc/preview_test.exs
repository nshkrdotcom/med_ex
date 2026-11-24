defmodule MedEx.PreviewTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription
  alias MedEx.Preview
  alias MedEx.Wav

  @tag :tmp_dir
  test "a receive-only peer receives live encoded PCM as Opus RTP", %{tmp_dir: dir} do
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

    {:ok, capture} =
      MedEx.Capture.start_link(owner: self(), acquisition_id: "rtc", artifact_dir: dir)

    :ok = MedEx.Capture.subscribe(capture)
    pcm = for i <- 0..959, into: <<>>, do: <<trunc(4000 * :math.sin(i / 20))::little-signed-16>>

    packet =
      Enum.reduce_while(0..19, nil, fn i, _ ->
        :ok = MedEx.Capture.push(capture, i * 960, pcm)

        receive do
          {:med_ex_preview, ^capture, index, packet} ->
            :ok = Preview.send_opus(preview, packet, 0, index)
            {:halt, packet}
        after
          25 -> {:cont, nil}
        end
      end)

    assert is_binary(packet)
    assert_receive {:ex_webrtc, ^receiver, {:rtp, _track_id, nil, %{payload: ^packet}}}, 2_000
    assert {:ok, _evidence} = MedEx.Capture.finish(capture)
  end

  test "truncated and partial-frame WAV input is rejected" do
    audio = Wav.encode_pcm16_wav(<<1, 2, 3, 4>>, 4_000)
    assert {:error, :invalid_wav_header} = Wav.parse_wav(binary_part(audio, 0, 47))

    <<prefix::binary-size(4), _size::little-32, body::binary-size(32), _length::little-32,
      data::binary>> = audio

    partial = <<prefix::binary, 40::little-32, body::binary, 3::little-32, data::binary>>
    assert {:error, :invalid_pcm_frames} = Wav.parse_wav(partial)
  end

  defp stop(pid) do
    if Process.alive?(pid), do: PeerConnection.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
