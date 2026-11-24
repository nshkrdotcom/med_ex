defmodule MedEx.FrameFingerprint do
  @moduledoc "Transport-independent semantic identity. Ingress keeps wire SHA separately."
  alias MedEx.{CanonicalJSON, SampleFrame}

  @spec of(SampleFrame.t()) :: String.t()
  def of(%SampleFrame{} = f) do
    fields = %{
      "descriptor_ref" => f.descriptor_ref,
      "stream_id" => f.stream_id,
      "source_epoch" => Integer.to_string(f.source_epoch),
      "sequence" => Integer.to_string(f.sequence),
      "first_sample" => Integer.to_string(f.first_sample),
      "sample_count" => Integer.to_string(f.sample_count),
      "config_epoch" =>
        if(f.config_epoch == :unknown, do: "unknown", else: Integer.to_string(f.config_epoch)),
      "payload_sha256" => hash(f.payload)
    }

    hash(["medex.frame.v1", 0, CanonicalJSON.encode(fields)])
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
