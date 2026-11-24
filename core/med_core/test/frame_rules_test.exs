defmodule MedEx.Capture.FrameRulesTest do
  use ExUnit.Case, async: true

  alias MedEx.Capture.FrameRules

  @frame :binary.copy(<<0, 0>>, 960)
  @limit 86_400_000

  test "exact ceiling, short final chunk, and full chunk" do
    assert {:ok, 960, false} = FrameRules.advance(0, false, 0, @frame)
    assert {:ok, @limit, false} = FrameRules.advance(@limit - 960, false, @limit - 960, @frame)
    assert {:ok, @limit, true} = FrameRules.advance(@limit - 1, false, @limit - 1, <<0, 0>>)
    assert :error = FrameRules.advance(@limit, false, @limit, <<0, 0>>)
  end

  test "rejects skipped, repeated, oversized, malformed and post-tail chunks" do
    for pcm <- [<<>>, <<0>>, <<0, 1, 2>>, @frame <> <<0, 0>>, :invalid] do
      assert :error = FrameRules.advance(0, false, 0, pcm)
    end

    assert :error = FrameRules.advance(0, false, 1, @frame)
    assert :error = FrameRules.advance(960, false, 0, @frame)
    assert :error = FrameRules.advance(1, true, 1, @frame)
  end
end
