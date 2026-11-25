defmodule MedEx.Storage.Journal do
  @moduledoc false
  alias MedEx.{CanonicalJSON, Serialization}
  @max_record 65_424
  @max_generations 100_000
  @max_bytes 268_435_456
  @zero String.duplicate("0", 64)
  def zero, do: @zero
  def max_bytes, do: @max_bytes

  # Separately authenticate the fixed header. A corrupt length cannot turn a
  # complete record into an apparently incomplete tail.
  def envelope(generation, previous, record) do
    payload = Serialization.bytes(record)

    if byte_size(payload) > @max_record or generation > @max_generations,
      do: throw({:invalid, :journal_limit})

    header =
      <<"MEJ1", byte_size(payload)::32, generation::64,
        Base.decode16!(previous, case: :lower)::binary>>

    check = :crypto.hash(:sha256, ["medex.header.v1", 0, header])
    digest = :crypto.hash(:sha256, ["medex.journal.v1", 0, header, check, payload])
    {[header, check, payload, digest], Base.encode16(digest, case: :lower)}
  end

  def fold(path, initial, apply_record) do
    with {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.lstat(path),
         {:ok, fd} <- :file.open(path, [:raw, :binary, :read]) do
      try do
        scan(fd, 1, @zero, 0, initial, apply_record)
      after
        :file.close(fd)
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_journal_file}
    end
  end

  defp scan(fd, gen, prev, pos, acc, apply_record) do
    case :file.read(fd, 80) do
      :eof ->
        {:ok, acc, pos, false}

      {:ok, short} when byte_size(short) < 80 ->
        # Only a final, incomplete envelope is recoverable.
        n = min(4, byte_size(short))

        if binary_part(short, 0, n) == binary_part("MEJ1", 0, n),
          do: {:ok, acc, pos, true},
          else: {:error, :journal_magic}

      {:ok,
       <<"MEJ1", length::32, ^gen::64, previous::binary-size(32), check::binary-size(32)>> =
           header}
      when length <= @max_record and gen <= @max_generations ->
        fields = binary_part(header, 0, 48)

        with true <- Base.encode16(previous, case: :lower) == prev,
             true <- :crypto.hash(:sha256, ["medex.header.v1", 0, fields]) == check do
          case :file.read(fd, length + 32) do
            :eof ->
              {:ok, acc, pos, true}

            {:ok, tail} when byte_size(tail) < length + 32 ->
              {:ok, acc, pos, true}

            {:ok, <<payload::binary-size(^length), digest::binary-size(32)>>} ->
              hex = Base.encode16(digest, case: :lower)

              with true <-
                     :crypto.hash(:sha256, ["medex.journal.v1", 0, header, payload]) == digest,
                   {:ok, record} <- CanonicalJSON.decode(payload),
                   {:ok, next} <- apply_record.(record, gen, hex, acc) do
                scan(fd, gen + 1, hex, pos + 112 + length, next, apply_record)
              else
                false -> {:error, :journal_digest}
                error -> error
              end

            error ->
              error
          end
        else
          false -> {:error, :journal_chain}
        end

      {:ok, _} ->
        {:error, :journal_header}

      error ->
        error
    end
  end
end
