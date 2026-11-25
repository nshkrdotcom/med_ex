defmodule MedEx.Storage do
  @moduledoc """
  A single temporary writer owns its adapter state. A commit receipt names the
  synchronized journal generation and its exclusive sequence/sample boundaries.
  An unclassified IO error after appending begins is an unknown outcome.
  """
  @type state :: term()
  @type result :: {:ok, state(), map()} | {:error, {:not_committed | :outcome_unknown, term()}}
  @callback open(keyword()) :: result()
  @callback commit_batch(state(), {:frames, [MedEx.SampleFrame.t()]} | {:gap, map()}) :: result()
  @callback usage(state()) :: %{
              raw_bytes: non_neg_integer(),
              frame_count: non_neg_integer(),
              span_count: non_neg_integer(),
              journal_bytes: non_neg_integer()
            }
  @callback lookup(state(), :frame | :gap, term()) :: {:ok, binary()} | :missing
  @callback seal(state(), :finished | :interrupted | :failed, binary() | %{conflict: map()}) ::
              {:ok, MedEx.StreamIndex.t()} | {:error, term()}
  @callback recover(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback close(state()) :: term()
end
