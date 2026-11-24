defmodule MedEx.Preview.ClockTest do
  use ExUnit.Case, async: true

  alias MedEx.Preview.Clock

  test "preserves dropped-frame gaps and steps one packet when the capture changes" do
    first = make_ref()
    second = make_ref()
    clock = Clock.advance(nil, first, 4_800)
    assert clock.tick == 4_800
    clock = Clock.advance(clock, first, 9_600)
    assert clock.tick == 9_600
    clock = Clock.advance(clock, second, 19_200)
    assert clock.tick == 10_560
    assert Clock.advance(clock, second, 21_120).tick == 12_480
  end
end
