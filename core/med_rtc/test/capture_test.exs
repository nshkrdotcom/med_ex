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
    assert {:ok, %{pcm: captured}} = MedRTC.WavCapture.parse_wav(bytes)
    assert captured == pcm <> <<3, 0>>
    assert evidence.file_sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert File.ls!(dir) == [evidence.artifact_key]
  end

  @tag :tmp_dir
  test "a source gap ends the attempt without a recording", %{tmp_dir: dir} do
    {:ok, capture} = MedEx.Capture.start_link(acquisition_id: "a", artifact_dir: dir)
    assert {:error, :invalid_frame} = MedEx.Capture.push(capture, 1, <<1, 0>>)
    assert File.ls!(dir) == []
  end
end
