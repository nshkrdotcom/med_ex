defmodule MedEx.Build.EcosystemGraph do
  @moduledoc false
  @separate ~w(weld-ci weld-minimum medex-remote fabric-remote)

  # Development feedback never substitutes for the release graph.
  def fast do
    [
      {"medex-tests", "med_ex", [], ["mix", "test"]},
      {"fabric-tests", "med_fabric", [], ["mix", "test"]}
    ]
  end

  def select(nodes, nil), do: Enum.reject(nodes, &(elem(&1, 0) in @separate))

  def select(nodes, id) do
    by_id = Map.new(nodes, &{elem(&1, 0), &1})
    required = prerequisites(by_id, id, MapSet.new())
    Enum.filter(nodes, &MapSet.member?(required, elem(&1, 0)))
  end

  def run(nodes, callback) do
    Enum.reduce(nodes, %{}, fn {id, _, parents, _} = node, results ->
      failed = Enum.reject(parents, &match?({:ok, _}, Map.get(results, &1)))

      result =
        if failed == [], do: execute(callback, node, results, parents), else: {:blocked, failed}

      report(id, result)
      Map.put(results, id, result)
    end)
  end

  defp execute(callback, node, results, parents) do
    previous = Map.new(parents, fn parent -> {parent, elem(results[parent], 1)} end)
    {:ok, callback.(node, previous)}
  rescue
    exception -> {:failed, Exception.message(exception)}
  catch
    kind, reason -> {:failed, "#{kind}: #{inspect(reason)}"}
  end

  def successful?(results), do: Enum.all?(results, fn {_, result} -> match?({:ok, _}, result) end)

  defp report(_id, {:ok, _}), do: :ok
  defp report(id, {:failed, message}), do: IO.puts("FAILED #{id}: #{message}")
  defp report(id, {:blocked, parents}), do: IO.puts("BLOCKED #{id}: #{Enum.join(parents, ", ")}")

  defp prerequisites(nodes, id, seen) do
    if MapSet.member?(seen, id) do
      seen
    else
      {_, _, parents, _} = Map.fetch!(nodes, id)
      Enum.reduce(parents, MapSet.put(seen, id), &prerequisites(nodes, &1, &2))
    end
  end
end
