defmodule MedEx.PackageTest do
  use ExUnit.Case, async: true

  test "the base application owns the SDK, starts no worker and carries the browser assets" do
    assert MedEx.Contract.api_revision() == 1

    for module <- [MedEx.StreamSpec, MedEx.Wire.FrameV1, MedEx.StreamWriter, MedEx.Web] do
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

    for name <- ~w(pcm_capture.js pcm_worklet.js session_hook.js) do
      path = MedEx.Web.asset_path(name)
      assert path == Application.app_dir(:med_ex, "priv/static/med_web/#{name}")
      assert byte_size(File.read!(path)) > 0
    end
  end
end
