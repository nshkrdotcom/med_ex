defmodule MedEx.Opus.CapturePreviewTest do
  use ExUnit.Case, async: true

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  @tag :tmp_dir
  test "encodes live preview and keeps writing when the subscriber stops demanding", %{
    tmp_dir: dir
  } do
    {:ok, capture} =
      MedEx.Capture.start_link(owner: self(), acquisition_id: "a", artifact_dir: dir)

    test_pid = self()

    spawn_link(fn ->
      :ok = MedEx.Capture.subscribe(capture)
      send(test_pid, :subscribed)

      receive do
        {:med_ex_preview_replaced, ^capture} -> send(test_pid, :replaced)
      end
    end)

    assert_receive :subscribed, 5_000
    assert :ok = MedEx.Capture.subscribe(capture)
    assert_receive :replaced
    refute_received {:med_ex_preview_replaced, ^capture}
    pcm = for i <- 0..959, into: <<>>, do: <<trunc(4000 * :math.sin(i / 20))::little-signed-16>>

    assert :ok = MedEx.Capture.push(capture, 0, pcm)
    assert_receive {:med_ex_preview, ^capture, 0, packet}, 5_000
    assert byte_size(packet) > 0
    assert :ok = MedEx.Capture.push(capture, 960, pcm)
    assert {:ok, evidence} = MedEx.Capture.finish(capture)
    assert evidence.sample_count == 1_920
    refute_received {:med_ex_preview, ^capture, _, _}
  end
end
