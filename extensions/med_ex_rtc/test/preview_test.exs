defmodule MedEx.PreviewTest do
  use ExUnit.Case, async: true

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  alias ExWebRTC.PeerConnection
  alias ExWebRTC.SessionDescription
  alias MedEx.Preview

  @tag :tmp_dir
  test "a receive-only peer receives Opus RTP", %{tmp_dir: dir} do
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

    pcm = for i <- 0..959, into: <<>>, do: <<trunc(4000 * :math.sin(i / 20))::little-signed-16>>

    packet = capture_and_encode(capture, pcm)
    :ok = Preview.send_opus(preview, packet, 0, 0)
    assert_receive {:ex_webrtc, ^receiver, {:rtp, _track_id, nil, %{payload: ^packet}}}, 2_000
    assert {:ok, _evidence} = MedEx.Capture.finish(capture)
  end

  defp capture_and_encode(capture, pcm) do
    case Application.get_env(:med_ex, :preview_provider) do
      nil ->
        assert {:error, :preview_unavailable} = MedEx.Capture.subscribe(capture)
        assert :ok = MedEx.Capture.push(capture, 0, pcm)
        # A 20 ms Opus silence frame exercises RTC without installing Opus.
        <<0xF8, 0xFF, 0xFE>>

      _provider ->
        assert :ok = MedEx.Capture.subscribe(capture)
        assert :ok = MedEx.Capture.push(capture, 0, pcm)
        assert_receive {:med_ex_preview, ^capture, 0, packet}, 5_000
        packet
    end
  end

  defp stop(pid) do
    if Process.alive?(pid), do: PeerConnection.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
