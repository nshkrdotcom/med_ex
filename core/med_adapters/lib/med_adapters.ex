defmodule MedAdapters do
  @moduledoc """
  Behaviour-driven clinical OSS adapter layer for MedEx.

  Defines isolated boundaries for in-BEAM ONNX inference, supervised Python
  biosignal workers, clinical archives (FHIR, WFDB, DICOMweb), and optional
  external media/voice-AI planes.
  """

  @spec core_version() :: String.t()
  def core_version, do: MedCore.version()
end
