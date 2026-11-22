defmodule MedAdapters.Inference do
  @moduledoc """
  Behaviour contract for advisory clinical inference adapters (e.g., Ortex/ONNX).

  All inference outputs carry SaMD advisory metadata and the input window's
  measured continuity so degraded or unverified windows are never surfaced clinically.
  """

  alias MedCore.Session

  @type advisory_result :: %{
          required(:advisory_only) => true,
          required(:model_sha256) => String.t(),
          required(:signal_quality_score) => float(),
          required(:continuity) => Session.continuity_state(),
          required(:payload) => map()
        }

  @callback infer(binary(), keyword()) :: {:ok, advisory_result()} | {:error, term()}
end
