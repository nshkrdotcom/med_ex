defmodule MedEx.Storage.Objects do
  @moduledoc false
  alias MedEx.{Serialization, Wav}
  @block 65_536

  def install(dir, name, bytes, hook) do
    temp = Path.join(dir, ".#{nonce()}.part")

    with {:ok, fd} <- :file.open(temp, [:raw, :binary, :write, :exclusive]) do
      try do
        with :ok <- :file.write(fd, bytes),
             :ok <- hook.(:before_object_sync),
             :ok <- :file.sync(fd),
             :ok <- hook.(:after_object_sync),
             :ok <-
               link(temp, Path.join(dir, name), byte_size(bytes), Serialization.sha256(bytes)),
             :ok <- Wav.sync_directory(dir),
             do: hook.(:after_object_install)
      after
        :file.close(fd)
        File.rm(temp)
      end
    end
  end

  def copy_prefix(from, dir, size) do
    temp = Path.join(dir, ".#{nonce()}.part")

    with {:ok, src} <- :file.open(from, [:raw, :binary, :read]) do
      try do
        with {:ok, dst} <- :file.open(temp, [:raw, :binary, :write, :exclusive]) do
          try do
            with {:ok, digest} <- transfer(src, dst, size, :crypto.hash_init(:sha256)),
                 :ok <- :file.sync(dst),
                 key = digest <> ".prefix",
                 :ok <- link(temp, Path.join(dir, key), size, digest),
                 :ok <- Wav.sync_directory(dir),
                 do: {:ok, key}
          after
            :file.close(dst)
            File.rm(temp)
          end
        end
      after
        :file.close(src)
      end
    end
  end

  defp transfer(_src, _dst, 0, hash),
    do: {:ok, :crypto.hash_final(hash) |> Base.encode16(case: :lower)}

  defp transfer(src, dst, left, hash) do
    case :file.read(src, min(left, @block)) do
      {:ok, bytes} ->
        with :ok <- :file.write(dst, bytes),
             do: transfer(src, dst, left - byte_size(bytes), :crypto.hash_update(hash, bytes))

      :eof ->
        {:error, :short_prefix}

      error ->
        error
    end
  end

  def verify(path, size, digest) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: ^size}} ->
        actual =
          File.stream!(path, @block)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        if actual == digest, do: :ok, else: {:error, :object_digest}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_object}
    end
  rescue
    e in File.Error -> {:error, e.reason}
  end

  def link(src, dst, size, digest) do
    case File.ln(src, dst) do
      :ok -> :ok
      {:error, :eexist} -> verify(dst, size, digest)
      error -> error
    end
  end

  def nonce, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
end
