defmodule MedEx.Build.Ownership do
  @moduledoc false
  def beam_inventory!(ebin, roots) do
    roots = Enum.map(roots, &(Path.expand(&1) <> "/"))

    for path <- Path.wildcard(Path.join(ebin, "*.beam")), into: %{} do
      {:ok, {mod, [compile_info: info]}} =
        :beam_lib.chunks(String.to_charlist(path), [:compile_info])

      file = info |> Keyword.fetch!(:source) |> to_string() |> Path.expand()

      unless Enum.any?(roots, &String.starts_with?(file, &1)),
        do: raise("unowned source #{file} in #{ebin}")

      {mod, file}
    end
  end

  def combine!(inventories) do
    Enum.reduce(inventories, %{}, fn inventory, all ->
      Map.merge(all, inventory, fn mod, a, b -> raise "duplicate module #{mod}: #{a}, #{b}" end)
    end)
  end
end
