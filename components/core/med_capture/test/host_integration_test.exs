defmodule MedEx.HostIntegrationTest do
  use ExUnit.Case, async: true
  alias MedEx.CaptureFixture, as: F
  alias MedEx.StreamWriter

  test "a supervisor and a distinct explicit owner share the single fenced manual writer" do
    fixture = F.root()
    on_exit(fn -> F.cleanup(fixture) end)
    {:ok, supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, writer} = DynamicSupervisor.start_child(supervisor, {StreamWriter, F.opts(fixture)})

    assert {:ok, %{accepted_sequence: 1, durable_sequence: 0}} =
             StreamWriter.push(writer, "f1", F.frame(0), 1000)

    refute_receive {:med_ex_durable, ^writer, _}, 300
    assert {:ok, receipt} = StreamWriter.checkpoint(writer, "f1", 1000)
    assert MedEx.Receipt.durable?(receipt)
    assert {:ok, terminal} = StreamWriter.finish(writer, "f1", 5000)
    assert terminal.recovered.index_status == :installed
    assert {:ok, recovered} = F.recover(fixture)
    assert MedEx.Receipt.exact_prefix?(terminal.receipt, recovered)
  end

  test "public startup refuses invalid owners/descriptors/options before creating bytes" do
    fixture = F.root()
    on_exit(fn -> F.cleanup(fixture) end)
    test_pid = self()
    probe = fn _ -> send(test_pid, :unexpected_hook) end

    for opts <- [
          F.opts(fixture, owner: nil),
          F.opts(fixture, fence: ""),
          F.opts(fixture, stream: %{}),
          F.opts(fixture, limits: %{pending_frames: 0})
        ] do
      assert {:error, _} = StreamWriter.start_link(opts)
      refute File.exists?(fixture.dir)
    end

    for opts <- [
          F.opts(fixture, storage: :not_allowed),
          F.opts(fixture, test_storage: :not_allowed),
          F.opts(fixture, fault_hook: probe),
          F.opts(fixture, _fault_hook: probe),
          F.opts(fixture, recovery_hook: probe),
          F.opts(fixture) ++ [fence: "dup"],
          :not_a_keyword,
          [{"fence", "f1"}]
        ] do
      assert {:error, :invalid_options} = StreamWriter.start_link(opts)
      refute_received :unexpected_hook
      refute File.exists?(fixture.dir)
    end
  end
end
