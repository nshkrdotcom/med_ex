defmodule MedAdapters.Inference do
  @moduledoc """
  Behaviour contract for advisory clinical inference adapters (e.g., Ortex/ONNX).

  All inference outputs carry SaMD advisory metadata and the input window's
  signal integrity state so degraded windows are never surfaced clinically.
  """

  alias MedCore.Session

  @type advisory_result :: %{
          required(:advisory_only) => true,
          required(:model_sha256) => String.t(),
          required(:signal_quality_score) => float(),
          required(:integrity_state) => Session.integrity_status(),
          required(:payload) => map()
        }

  @callback infer(binary(), keyword()) :: {:ok, advisory_result()} | {:error, term()}
end
