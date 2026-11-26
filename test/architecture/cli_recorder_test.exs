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
end
