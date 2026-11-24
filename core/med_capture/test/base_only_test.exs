defmodule MedEx.BaseOnlyTest do
  use ExUnit.Case, async: true
  @tag :tmp_dir
  test "no installed encoder is needed for canonical evidence", %{tmp_dir: dir} do
    {:ok, pid} =
      MedEx.Capture.start_link(
        owner: self(),
        artifact_dir: dir,
        acquisition_id: "headless",
        preview_provider: nil
      )

    assert {:error, :preview_unavailable} = MedEx.Capture.subscribe(pid)
    assert :ok = MedEx.Capture.push(pid, 0, <<1, 0>>)
    assert {:ok, %MedEx.Evidence{sample_count: 1}} = MedEx.Capture.finish(pid)
    assert {:error, :rtc_unavailable} = MedEx.Preview.answer("sdp")
  end
end
