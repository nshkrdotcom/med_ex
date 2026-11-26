defmodule MedEx.CliRecorderTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  test "second reference host (tools/cli_recorder.exs) records, seals, and recovers", %{
    tmp_dir: dir
  } do
    on_exit(fn -> File.rm_rf!(dir) end)
    script = Path.expand("../../tools/cli_recorder.exs", __DIR__)
    assert File.regular?(script)

    {out, 0} =
      System.cmd("mix", ["run", script, dir, "4"],
        cd: Path.expand("../..", __DIR__),
        stderr_to_stdout: true
      )

    assert out =~ "cli_recorder ok frames=4"
    assert out =~ "sealed=true"
  end

  test "invalid frame counts are rejected before creating a recording", %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    script = Path.expand("../../tools/cli_recorder.exs", __DIR__)

    for count <- ["0", "-1", "invalid", "1.5"] do
      output_dir = Path.join(dir, count)

      {out, status} =
        System.cmd("mix", ["run", script, output_dir, count],
          cd: Path.expand("../..", __DIR__),
          stderr_to_stdout: true
        )

      assert status != 0
      assert out =~ "frame_count must be a positive integer"
      refute File.exists?(output_dir)
    end
  end
end
