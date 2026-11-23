defmodule MedEx.CaptureTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "commits exactly the indexed PCM including the final short frame", %{tmp_dir: dir} do
    {:ok, capture} = MedEx.Capture.start_link(acquisition_id: "a", artifact_dir: dir)
    pcm = :binary.copy(<<2, 0>>, 960)
    assert :ok = MedEx.Capture.push(capture, 0, pcm)
    assert :ok = MedEx.Capture.push(capture, 960, <<3, 0>>)
    assert {:ok, evidence} = MedEx.Capture.finish(capture)
    assert evidence.sample_count == 961
    assert evidence.end_sample == 961
    assert evidence.kind == :audio_pcm16_wav
    bytes = File.read!(Path.join(dir, evidence.artifact_key))
    assert {:ok, %{pcm: captured}} = MedEx.Wav.parse_wav(bytes)
    assert captured == pcm <> <<3, 0>>
    assert evidence.file_sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert File.ls!(dir) == [evidence.artifact_key]
  end

  @tag :tmp_dir
  test "encodes live preview and keeps writing when the subscriber stops demanding", %{
    tmp_dir: dir
  } do
    {:ok, capture} = MedEx.Capture.start_link(acquisition_id: "a", artifact_dir: dir)
    assert :ok = MedEx.Capture.subscribe(capture)
    pcm = for i <- 0..959, into: <<>>, do: <<trunc(4000 * :math.sin(i / 20))::little-signed-16>>

    index =
      Enum.reduce_while(0..19, nil, fn frame, _ ->
        assert :ok = MedEx.Capture.push(capture, frame * 960, pcm)

        receive do
          {:med_ex_preview, ^capture, index, packet} ->
            assert byte_size(packet) > 0
            {:halt, {frame, index}}
        after
          25 -> {:cont, nil}
        end
      end)

    assert {frame, sent} = index
    assert sent <= frame * 960
    assert :ok = MedEx.Capture.push(capture, (frame + 1) * 960, pcm)
    assert {:ok, evidence} = MedEx.Capture.finish(capture)
    assert evidence.sample_count == (frame + 2) * 960
    refute_received {:med_ex_preview, ^capture, _, _}
  end

  @tag :tmp_dir
  test "a source gap ends the attempt without a recording", %{tmp_dir: dir} do
    {:ok, capture} = MedEx.Capture.start_link(acquisition_id: "a", artifact_dir: dir)
    assert {:error, :invalid_frame} = MedEx.Capture.push(capture, 1, <<1, 0>>)
    assert File.ls!(dir) == []
  end
end
