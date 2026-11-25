defmodule MedEx.PreviewProvider do
  @moduledoc """
  Explicit optional encoder port. start_link options bind owner, format and session ID.
  A granted offer produces {:med_ex_encoded, operation_id, sample_index, payload}
  or {:med_ex_encode_failed, operation_id, reason} to that owner. At most one
  offer is in flight. Native providers belong outside the authoritative VM in
  the strict deployment profile. These callbacks do not grant storage access.
  """
  @callback start_legacy(owner :: pid()) :: {:ok, pid(), pid()} | {:error, term()}
  @optional_callbacks start_legacy: 1
  @callback start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  @callback offer(pid(), term(), non_neg_integer(), binary()) :: :ok | {:error, :busy | term()}
  @callback stop(pid()) :: :ok
end
