defmodule MedEx.Wav do
  @moduledoc false

  @doc false
  def header(data_size, sample_rate_hz) do
    <<"RIFF", 36 + data_size::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, sample_rate_hz::little-32, sample_rate_hz * 2::little-32, 2::little-16,
      16::little-16, "data", data_size::little-32>>
  end

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
