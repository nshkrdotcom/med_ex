defmodule MedEx.Wav do
  @moduledoc "Legacy canonical PCM WAV helpers."
  defdelegate header_size(), to: MedEx.Format.Wav
  defdelegate parse_header(header, size), to: MedEx.Format.Wav
  @doc "Builds a PCM WAV header for the given payload size and sample rate."
  defdelegate header(size, rate), to: MedEx.Format.Wav
  @doc false
  def sync_directory(dir) do
    with {:ok, fd} <- :file.open(String.to_charlist(dir), [:read, :raw, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end
end
