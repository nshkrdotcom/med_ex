defmodule PulseScopeTest do
  use ExUnit.Case, async: true

  alias PulseScope.ClinicalProfile

  test "skeleton profile declares the expected streams" do
    assert PulseScope.profile() == ClinicalProfile
    assert ClinicalProfile.topology() == :server_terminated

    stream_ids = Enum.map(ClinicalProfile.streams(), & &1.id)
    assert stream_ids == ["auscultation", "vitals_telemetry", "device_control", "talkback_voice"]
  end
end
