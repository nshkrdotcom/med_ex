Code.require_file("boundary_check.exs", __DIR__)
Code.require_file("public_api.exs", __DIR__)

defmodule MedEx.Build.Architecture do
  @moduledoc false
  alias MedEx.Build.{Boundaries, Ownership, PublicAPI}

  def check!(root, projection, report) do
    {composition, _} = Code.eval_file(Path.join(root, "build_support/composition.exs"))

    source_roots =
      for project <- composition.components do
        {component_app(project), Path.join([root, project, "lib"])}
      end

    proofs =
      for {app, lib} <- source_roots, into: %{} do
        directory = Path.dirname(lib)
        inventory = Ownership.beam_inventory!(ebin(directory, app), [{app, lib}])
        if map_size(inventory) == 0, do: raise("missing proof build for #{app}")
        {app, inventory}
      end

    expected = Ownership.combine!(Map.values(proofs))
    direct = Mix.Project.compile_path()

    unless Ownership.beam_inventory!(direct, source_roots) == expected,
      do: raise("direct/component BEAM inventories differ")

    PublicAPI.check!()
    trace!(expected, source_roots, Map.keys(Map.fetch!(proofs, :med_core)))

    if projection,
      do: compare!(projection, report, root, direct, composition, expected, source_roots)

    IO.puts("Verified #{map_size(expected)} compiled SDK modules against the component builds")
  end

  defp trace!(inventory, source_roots, core_modules) do
    files =
      inventory
      |> Map.values()
      |> Enum.map(fn {app, relative} ->
        Path.join(Keyword.fetch!(source_roots, app), relative)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    previous = Code.compiler_options()
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp = Path.join(System.tmp_dir!(), "medex-trace-#{suffix}")
    File.mkdir!(tmp)

    try do
      Boundaries.configure(source_roots, core_modules)
      Enum.each(files, &Boundaries.ast!(&1, File.read!(&1)))
      Code.compiler_options(tracers: [Boundaries], ignore_module_conflict: true)

      case Kernel.ParallelCompiler.compile_to_path(files, tmp, return_diagnostics: true) do
        {:ok, _, %{compile_warnings: [], runtime_warnings: []}} -> :ok
        result -> raise "compiler boundary trace failed: #{inspect(result)}"
      end
    after
      Boundaries.clear()

      Code.compiler_options(
        tracers: previous.tracers,
        ignore_module_conflict: previous.ignore_module_conflict
      )

      File.rm_rf!(tmp)
    end
  end

  defp compare!(projection, report, root, direct, composition, expected, source_roots) do
    %{"schema" => "weld.result/2", "ok" => true, "data" => data} =
      report |> File.read!() |> JSON.decode!()

    kind = projection_kind!(projection, root)

    artifact = data["artifact"]
    verify_closure!(data, artifact, composition)

    files = artifact["source_inventory"]
    compile_sources = index(files, "compiled")

    package_files =
      for %{"publish" => true, "target" => path} <- artifact["output_inventory"], do: path

    projected_roots =
      for project <- composition.components do
        app = component_app(project)
        expected_root = source_roots |> Keyword.fetch!(app) |> Path.relative_to(root)

        inputs =
          for {^app, relative} <- Map.values(expected),
              do: {Path.join(expected_root, relative), relative}

        lib_paths =
          Enum.map(inputs, fn {source, relative} ->
            target = compare_input!(compile_sources, source, root, projection, project)
            projected_lib!(target, relative, package_files)
          end)

        [lib_path] = Enum.uniq(lib_paths)
        {app, Path.join(projection, lib_path)}
      end

    projected = ebin(projection, :med_ex)

    allowed_roots =
      if kind == "live", do: projected_roots ++ source_roots, else: projected_roots

    unless Ownership.beam_inventory!(projected, allowed_roots) == expected,
      do: raise("projected/component BEAM inventories differ")

    unless application_metadata!(projected) == application_metadata!(direct),
      do: raise("direct and projected OTP application metadata differ")

    verify_test_inputs!(files, root, projection, composition, package_files)

    IO.puts("Verified the #{kind} base closure, module ownership, tests and assets")
  end

  defp projection_kind!(projection, root) do
    cond do
      projection == Path.join(root, ".weld/v2/live/med_ex") -> "live"
      projection == Path.join(root, ".weld/v2/full/med_ex/project") -> "full"
      true -> raise("Use the managed Weld v2 live or full projection")
    end
  end

  defp verify_closure!(data, artifact, composition) do
    components = Enum.sort(composition.components)

    unless data["artifact_id"] == "med_ex" and data["layout"] == "components" and
             Enum.sort(artifact["dependency_projects"]) == components and
             Enum.sort(artifact["selected_projects"]) == components,
           do: raise("Weld closure differs from the declared base composition")
  end

  defp projected_lib!(target, relative, package_files) do
    unless covered?(target, package_files),
      do: raise("compiler source missing from the Hex allowlist: #{target}")

    unless String.ends_with?(target, "/" <> relative),
      do: raise("projected source moved out of its owning compiler root: #{target}")

    String.replace_suffix(target, "/" <> relative, "")
  end

  defp verify_test_inputs!(files, root, projection, composition, package_files) do
    test_sources = Map.merge(index(files, "test"), index(files, "artifact_test"))

    suites =
      Enum.map(composition.components, &{Path.join(&1, "test"), &1}) ++
        [{"test/projection", nil}]

    for {suite, owner} <- suites do
      paths =
        root
        |> Path.join(suite)
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)

      if paths == [], do: raise("missing verification files for #{suite}")

      Enum.each(
        paths,
        &verify_test_input!(&1, test_sources, root, projection, owner, package_files)
      )
    end
  end

  defp verify_test_input!(file, test_sources, root, projection, owner, package_files) do
    source = Path.relative_to(file, root)
    target = compare_input!(test_sources, source, root, projection, owner)

    if covered?(target, package_files),
      do: raise("verification input reached the published allowlist: #{target}")
  end

  defp compare_input!(index, source, root, projection, owner) do
    case Map.fetch(index, source) do
      {:ok, %{"owner" => ^owner, "target" => target}} ->
        unless File.read!(Path.join(root, source)) == File.read!(Path.join(projection, target)),
          do: raise("projected input differs from its source: #{source}")

        target

      _ ->
        raise "projected input is missing or has the wrong owner: #{source}"
    end
  end

  defp index(files, kind) do
    for %{"kind" => ^kind, "source" => path} = entry <- files, into: %{}, do: {path, entry}
  end

  defp covered?(path, roots) do
    Enum.any?(roots, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp application_metadata!(ebin) do
    file = Path.join(ebin, "med_ex.app") |> String.to_charlist()
    {:ok, [{:application, :med_ex, properties}]} = :file.consult(file)

    properties
    |> Keyword.take([:vsn, :description, :mod, :applications, :included_applications, :modules])
    |> Keyword.update!(:applications, &Enum.sort/1)
    |> Keyword.update!(:modules, &Enum.sort/1)
    |> Enum.sort()
  end

  defp ebin(project, app),
    do: Path.join([project, "_build", "test", "lib", to_string(app), "ebin"])

  defp component_app(project), do: project |> Path.basename() |> String.to_atom()
end

root = Path.expand("..", __DIR__)
MedEx.Build.Architecture.check!(root, List.first(System.argv()), Enum.at(System.argv(), 1))
