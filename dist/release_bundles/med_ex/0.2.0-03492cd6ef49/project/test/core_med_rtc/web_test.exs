defmodule MedEx.WebTest do
  use ExUnit.Case, async: true

  test "all public browser assets resolve in the owning OTP application" do
    for name <- ~w(session_hook.js pcm_capture.js pcm_worklet.js) do
      path = MedEx.Web.asset_path(name)

      assert Path.type(path) == :absolute
      assert File.regular?(path)
      assert byte_size(File.read!(path)) > 0
    end
  end

  test "asset lookup only accepts the three public filenames" do
    assert_raise FunctionClauseError, fn -> MedEx.Web.asset_path("../mix.exs") end
    assert_raise FunctionClauseError, fn -> MedEx.Web.asset_path("unknown.js") end
  end
end
