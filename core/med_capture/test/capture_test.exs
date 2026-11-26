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
  test "a stalled preview expires, recording continues and the subscriber can reconnect", %{
    tmp_dir: dir
  } do
    test = self()

    start = fn ->
      session = self()

      encoder =
        spawn_link(fn ->
          receive do
            {:pcm, index, _} -> send(session, {:preview_encoded, self(), index, "encoded"})
          end

          Process.sleep(:infinity)
        end)

      send(test, {:encoder, encoder, session})
      send(session, {:preview_ready, encoder})
      {:ok, encoder, encoder}
    end

    {:ok, capture} =
      MedEx.Capture.start_link(
        owner: test,
        acquisition_id: "a",
        artifact_dir: dir,
        start_preview_encoder: start
      )

    assert :ok = MedEx.Capture.subscribe(capture)
    assert_receive {:encoder, stalled, old_session}
    :erlang.suspend_process(stalled)
    pcm = :binary.copy(<<1, 0>>, 960)
    assert :ok = MedEx.Capture.push(capture, 0, pcm)
    assert :ok = MedEx.Capture.push(capture, 960, pcm)
    assert_receive {:med_ex_preview_failed, ^capture, :timeout}, 2_000
    assert :ok = MedEx.Capture.subscribe(capture)
    send(capture, {:preview_encode_timeout, old_session, 0})
    send(capture, {:preview_encoded, old_session, 0, "late"})
    assert :ok = MedEx.Capture.push(capture, 1920, pcm)
    assert_receive {:med_ex_preview, ^capture, 1920, "encoded"}
    refute_received {:med_ex_preview, ^capture, 0, _}
    assert {:ok, %{sample_count: 2880}} = MedEx.Capture.finish(capture)
  end

  @tag :tmp_dir
  test "a source gap ends the attempt without a recording", %{tmp_dir: dir} do
    {:ok, capture} =
      MedEx.Capture.start_link(owner: self(), acquisition_id: "a", artifact_dir: dir)

    assert {:error, :invalid_frame} = MedEx.Capture.push(capture, 1, <<1, 0>>)
    assert File.ls!(dir) == []
  end
end
