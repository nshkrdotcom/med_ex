defmodule MedAdapters do
  @moduledoc """
  Behaviour-driven clinical signal and media adapter layer for MedEx.

  Defines isolated boundaries for in-BEAM ONNX inference, supervised Python
  biosignal workers, and optional external media/voice-AI planes. Durable
  clinical outbox storage and FHIR/HL7 delivery belong to `med_fabric`.
  """

  @spec core_version() :: String.t()
  def core_version, do: MedCore.version()
end
