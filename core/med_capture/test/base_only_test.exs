defmodule MedEx.BaseOnlyTest do
  use ExUnit.Case, async: true
  alias MedEx.CaptureFixture, as: F

  test "writer startup returns a refusal without exiting its caller" do
    assert {:error, :invalid_writer_options} = MedEx.StreamWriter.start_link(owner: self())
  end

  test "base records and verifies exact PCM with no codec or RTC runtime" do
    fixture = F.root()
    on_exit(fn -> F.cleanup(fixture) end)
    {:ok, writer} = F.start(fixture)
    {:ok, _} = MedEx.StreamWriter.push(writer, "f1", F.frame(0), 1000)
    {:ok, durable} = MedEx.StreamWriter.checkpoint(writer, "f1", 1000)
    {:ok, terminal} = MedEx.StreamWriter.finish(writer, "f1", 5000)
    {:ok, recovered} = F.recover(fixture, known_receipt: durable)
    assert MedEx.Receipt.exact_prefix?(terminal.receipt, recovered)
    {:ok, index} = F.verified(recovered)

    assert {:ok, F.frame(0).payload} ==
             MedEx.Storage.File.read_verified_segment(index, 0, F.expected(recovered))

    runtime =
      Application.spec(:med_ex, :applications) || Application.spec(:med_capture, :applications)

    refute :med_ex_opus in runtime
    refute :med_ex_rtc in runtime
  end
end
