defmodule MedEx.Build.Ownership do
  @moduledoc false

  def source_owner(file, roots) do
    file = Path.expand(file)

    Enum.find_value(roots, fn {owner, root} ->
      root = Path.expand(root)

      if String.starts_with?(file, root <> "/"),
        do: {owner, Path.relative_to(file, root)}
    end)
  end

  def beam_inventory!(ebin, roots) do
    for path <- Path.wildcard(Path.join(ebin, "*.beam")), into: %{} do
      {:ok, {mod, [compile_info: info]}} =
        :beam_lib.chunks(String.to_charlist(path), [:compile_info])

      file = info |> Keyword.fetch!(:source) |> to_string() |> Path.expand()
      owner = source_owner(file, roots) || raise("unowned source #{file} in #{ebin}")

      {mod, owner}
    end
  end

  def combine!(inventories) do
    Enum.reduce(inventories, %{}, fn inventory, all ->
      Map.merge(all, inventory, fn mod, a, b ->
        raise "duplicate module #{mod}: #{inspect(a)}, #{inspect(b)}"
      end)
    end)
  end
end
