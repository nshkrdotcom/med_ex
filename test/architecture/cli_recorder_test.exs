defmodule MedEx.CliRecorderTest do
  use ExUnit.Case, async: true

  setup do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), "mf-source-test-" <> suffix)
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir}
  end

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
