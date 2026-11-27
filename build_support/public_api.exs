defmodule MedEx.Build.PublicAPI do
  @moduledoc false
  # Runtime visibility and supported use are distinct: storage must export its
  # behaviour callbacks to the writer, but hosts may call only the four reads.
  @supported %{
    MedEx.Contract => [api_revision: 0],
    MedEx.Receipt => [
      parse: 1,
      to_map: 1,
      validate_identity: 2,
      durable?: 1,
      durable_prefix: 1,
      observe: 2,
      committed_successor: 3,
      exact_prefix?: 2,
      handoff: 3,
      terminal_receipt: 3
    ],
    MedEx.StreamWriter => [
      start_link: 1,
      push: 4,
      record_gap: 4,
      checkpoint: 3,
      finish: 3,
      interrupt: 4,
      receipt: 3,
      stats: 3
    ],
    MedEx.Storage.File => [
      recover: 2,
      reconcile_terminal: 2,
      read_verified_index: 3,
      read_verified_segment: 3
    ],
    MedEx.Format.Wav => [header: 4],
    MedEx.Wire.Credit => [
      new: 1,
      new: 2,
      new: 3,
      reserve: 3,
      acknowledge: 3,
      refuse: 4,
      lookup: 3,
      invalidate: 1,
      stats: 1
    ],
    MedEx.RecordingLimits => [
      new: 1,
      maximum: 0,
      max_record_bytes: 0,
      envelope_bytes: 0,
      encoded_record_bytes: 1,
      terminal_reserve_bytes: 0,
      admit: 5
    ]
  }
  @internal %{
    MedEx.StreamWriter => [
      child_spec: 1,
      init: 1,
      handle_call: 3,
      handle_cast: 2,
      handle_info: 2,
      terminate: 2,
      code_change: 3
    ],
    MedEx.Storage.File => [open: 1, commit_batch: 2, usage: 1, lookup: 3, seal: 3, close: 1]
  }
  @generated [__struct__: 0, __struct__: 1, __info__: 1, module_info: 0, module_info: 1]

  def supported, do: @supported

  def check! do
    for {module, supported} <- @supported do
      Code.ensure_compiled!(module)
      internal = Map.get(@internal, module, [])
      actual = module.__info__(:functions) -- (@generated -- internal)

      unless Enum.sort(actual) == Enum.sort(supported),
        do: raise("public export drift in #{inspect(module)}: #{inspect(actual)}")
    end

    :ok
  end
end
