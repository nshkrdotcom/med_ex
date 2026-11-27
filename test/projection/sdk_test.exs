defmodule MedEx.PackageTest do
  use ExUnit.Case, async: true

  test "the base application owns the SDK, starts no worker" do
    assert MedEx.Contract.api_revision() == 2

    for module <- [
          MedEx.StreamSpec,
          MedEx.Wire.FrameV1,
          MedEx.StreamWriter,
          MedEx.Receipt,
          MedEx.Wire.Credit
        ] do
      assert Application.get_application(module) == :med_ex
    end

    assert Application.spec(:med_ex, :mod) in [nil, []]

    assert MapSet.new(Application.spec(:med_ex, :applications)) ==
             MapSet.new([:kernel, :stdlib, :elixir, :logger, :crypto])

    refute Enum.any?(Map.keys(Mix.Project.deps_paths()), fn app ->
             app in [
               :med_core,
               :med_capture,
               :med_ex_opus,
               :med_ex_rtc,
               :weld,
               :mix_workspace_ops
             ]
           end)

    assert function_exported?(MedEx.StreamWriter, :push, 4)
    refute function_exported?(MedEx.StreamWriter, :push, 2)
    refute File.exists?(Application.app_dir(:med_ex, "priv/static"))
  end
end
