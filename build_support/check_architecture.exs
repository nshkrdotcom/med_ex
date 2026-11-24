Code.require_file("boundary_check.exs", __DIR__)
alias MedEx.Build.{Boundaries, Ownership}
root = Path.expand("..", __DIR__)
core = Path.join(root, "core/med_core/lib")
capture = Path.join(root, "core/med_capture/lib")

inventory = fn app, source ->
  ebin = Path.join([root, "core", app, "_build", "test", "lib", app, "ebin"])
  inv = Ownership.beam_inventory!(ebin, [source])
  if map_size(inv) == 0, do: raise("missing proof build: #{ebin}")
  inv
end

pure = inventory.("med_core", core)
runtime = inventory.("med_capture", capture)
all = Ownership.combine!([pure, runtime])

unless all == Ownership.beam_inventory!(Mix.Project.compile_path(), [core, capture]),
  do: raise("root/component BEAM inventory mismatch")

:persistent_term.put({Boundaries, :core}, MapSet.new(Map.keys(pure)))
files = all |> Map.values() |> Enum.uniq()
for file <- files, do: Boundaries.ast!(file, File.read!(file))
previous = Code.compiler_options()
tmp = Path.join(System.tmp_dir!(), "medex-trace-#{System.unique_integer([:positive])}")
File.mkdir!(tmp)

try do
  Code.compiler_options(tracers: [Boundaries], ignore_module_conflict: true)

  case Kernel.ParallelCompiler.compile_to_path(files, tmp, return_diagnostics: true) do
    {:ok, _, %{compile_warnings: [], runtime_warnings: []}} -> :ok
    result -> raise "compiler boundary trace failed: #{inspect(result)}"
  end
after
  Code.compiler_options(
    tracers: previous.tracers,
    ignore_module_conflict: previous.ignore_module_conflict
  )

  File.rm_rf!(tmp)
end

IO.puts("Verified #{map_size(all)} compiled SDK modules against both proof components")
