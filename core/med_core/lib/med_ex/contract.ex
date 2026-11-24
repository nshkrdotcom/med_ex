defmodule MedEx.Contract do
  @moduledoc "A source contract revision, independent of unchanged package release versions."
  @spec api_revision() :: 1
  def api_revision, do: 1
end
