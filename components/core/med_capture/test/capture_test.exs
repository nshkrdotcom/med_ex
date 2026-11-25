defmodule MedEx.CaptureTest do
  use ExUnit.Case, async: true

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  @tag :tmp_dir
  test "producer death removes the unfinished recording", %{tmp_dir: dir} do
    test_pid = self()

    producer =
      spawn(fn ->
        receive do
          {:write, capture} ->
            send(
              test_pid,
              {:written, MedEx.Capture.push(capture, 0, :binary.copy(<<1, 0>>, 960))}
            )

            Process.sleep(:infinity)
        end
      end)

    {:ok, capture} =
      MedEx.Capture.start_link(owner: producer, acquisition_id: "a", artifact_dir: dir)

    ref = Process.monitor(capture)
    assert {:error, :not_owner} = MedEx.Capture.finish(capture)
    assert {:error, :not_owner} = MedEx.Capture.push(capture, 1, <<0>>)
    send(producer, {:write, capture})
    assert_receive {:written, :ok}
    Process.exit(producer, :kill)
    assert_receive {:DOWN, ^ref, :process, ^capture, :normal}, 1000
    assert File.ls!(dir) == []
  end

  @tag :tmp_dir
  test "commits exactly the indexed PCM including the final short frame", %{tmp_dir: dir} do
    {:ok, capture} =
      MedEx.Capture.start_link(owner: self(), acquisition_id: "a", artifact_dir: dir)

    pcm = :binary.copy(<<2, 0>>, 960)
    assert :ok = MedEx.Capture.push(capture, 0, pcm)
    assert :ok = MedEx.Capture.push(capture, 960, <<3, 0>>)
    assert {:ok, evidence} = MedEx.Capture.finish(capture)
    assert evidence.sample_count == 961
    assert evidence.end_sample == 961
    assert evidence.kind == :audio_pcm16_wav
    bytes = File.read!(Path.join(dir, evidence.artifact_key))
    expected_pcm = pcm <> <<3, 0>>

    assert <<"RIFF", 1958::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
             48_000::little-32, 96_000::little-32, 2::little-16, 16::little-16, "data",
             1922::little-32, ^expected_pcm::binary>> = bytes

    assert evidence.pcm_sha256 == Base.encode16(:crypto.hash(:sha256, expected_pcm), case: :lower)
    assert evidence.file_sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert evidence.artifact_key == evidence.file_sha256 <> ".wav"
    assert File.ls!(dir) == [evidence.artifact_key]
  end

  @tag :tmp_dir
  test "a source gap ends the attempt without a recording", %{tmp_dir: dir} do
    {:ok, capture} =
      MedEx.Capture.start_link(owner: self(), acquisition_id: "a", artifact_dir: dir)

    assert {:error, :invalid_frame} = MedEx.Capture.push(capture, 1, <<1, 0>>)
    assert File.ls!(dir) == []
  end
end
