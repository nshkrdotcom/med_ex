defmodule MedEx.Storage do
  @moduledoc false
  alias MedEx.Storage.{Transfer, Usage}

  @callback open(keyword()) ::
              Transfer.t() | {:error, {:not_committed | :outcome_unknown, term()}}
  @callback commit_batch(term(), {:frames, [MedEx.SampleFrame.t()]} | {:gap, map()}) ::
              Transfer.t()
  @callback usage(term()) :: Usage.t()
  @callback lookup(term(), :frame | :gap, term()) :: {:ok, binary()} | :missing
  @callback seal(term(), :finished | :interrupted | :failed, term()) :: Transfer.t()
  @callback close(term()) :: :ok | {:error, term()}
end

defmodule MedEx.Storage.Transfer do
  @moduledoc false
  @enforce_keys [:handle, :result]
  defstruct @enforce_keys
  @type t :: %__MODULE__{handle: term(), result: {:ok, term()} | {:error, term()}}
end

defmodule MedEx.Storage.Usage do
  @moduledoc false
  @enforce_keys [:raw_bytes, :frame_count, :span_count, :journal_bytes, :journal_generation]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule MedEx.Storage.RecoveredPrefix do
  @moduledoc "Verified read-only journal facts. Provenance is scoped to one exclusive root owner."
  @enforce_keys [
    :artifact_dir,
    :stream,
    :fence,
    :receipt,
    :cursor,
    :index,
    :index_digest,
    :terminal_recorded,
    :index_status,
    :sealed,
    :torn_tail,
    :provenance
  ]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule MedEx.Storage.Terminal do
  @moduledoc "An installed immutable terminal index and its exact verified journal receipt."
  @enforce_keys [:index, :receipt, :recovered]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end

defmodule MedEx.Storage.VerifiedIndex do
  @moduledoc "An immutable index bound to an authorized manifest and exclusive root provenance."
  @enforce_keys [:artifact_dir, :index, :index_digest, :manifest_digest, :provenance, :segments]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end
