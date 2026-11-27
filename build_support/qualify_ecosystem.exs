Code.require_file("qualification_scope.exs", __DIR__)
Code.require_file("ecosystem_graph.exs", __DIR__)
Code.require_file("qualification_sources.exs", __DIR__)

defmodule MedEx.Build.EcosystemQC do
  @moduledoc false
  alias MedEx.Build.EcosystemGraph, as: Graph
  alias MedEx.Build.QualificationReceipt, as: Receipt
  alias MedEx.Build.QualificationScope, as: Scope

  @default_root Path.expand("../..", __DIR__)
  @switches [
    repos: :string,
    evidence: :string,
    base: :string,
    jobs: :integer,
    gate: :string,
    strict: :boolean,
    no_cache: :boolean,
    keep_failure: :boolean,
    volume: :string,
    enospc_root: :string,
    artifacts: :string
  ]
  @usage """
  Usage: build_support/qualify_ecosystem.sh plan|dev|fast|full|resume|status [options]
    --repos DIR      Parent directory of med_ex and med_fabric
    --base REV       Change base for plan/dev (default HEAD in each repo)
    --evidence DIR   Private receipt directory, required for resume/status
    --gate ID        Execute a single gate and its prerequisites
    --jobs N         Max concurrent MedEx cells, 1–4 (default 2)
    --strict         Run the exhaustive MedEx matrix
    --no-cache       Re-execute selected gates
    --keep-failure   Retain private intermediate diagnostics where supported
    --volume DIR     Existing disposable ext4 volume for both 1740-second soaks
    --enospc-root DIR Dedicated marked ext4 loop mount for physical SDK ENOSPC
    --artifacts FILE Exact six-tar manifest for detached candidate/official proof
  Bootstrap genuine dependencies once before fast/full: mix setup in each repo.
  Fast runs the two bounded source-quality gates and records reusable receipts.
  It permits the explicit Fabric development source selector; full does not.
  Full/resume select local consumer proof from clean committed sources and
  exact candidate archives. Released Weld 0.20.2 is the tool, not a CI target.
  Remote Git proof requires explicit --gate medex-remote or fabric-remote.
  Weld source CI/minimum require their explicit --gate and sibling checkout.
  This runner performs no push, publication, activation or retained-data reset.
  """
  @mix_overrides ~w(MIX_ENV MIX_EXS MIX_TARGET MIX_DEPS_PATH MIX_LOCKFILE MIX_BUILD_PATH MIX_BUILD_ROOT)
  @outside_services ~w(DATABASE_URL FHIR_BASE_URL SSLKEYLOGFILE)
  @hex_overrides ~w(HEX_API_KEY HEX_TOKEN HEX_API_URL HEX_MIRROR HEX_MIRROR_URL HEX_TRUSTED_MIRROR
                    HEX_TRUSTED_MIRROR_URL HEX_OFFLINE HEX_UNSAFE_HTTPS HEX_UNSAFE_REGISTRY
                    HEX_NO_VERIFY_REPO_ORIGIN)

  def main(argv) do
    case argv do
      ["--help"] ->
        IO.puts(@usage)

      [mode | switches] when mode in ~w(plan dev fast full resume status) ->
        {opts, [], []} = OptionParser.parse(switches, strict: @switches)
        config = configuration(mode, opts)

        case mode do
          "plan" -> print_plan(config, opts)
          "status" -> status(config)
          _ -> execute(config, mode, opts)
        end

      _ ->
        raise ArgumentError, @usage
    end
  end

  defp configuration(mode, opts) do
    root = Path.expand(opts[:repos] || @default_root)
    jobs = opts[:jobs] || 2
    unless jobs in 1..4, do: raise("--jobs must be between 1 and 4")
    if mode in ~w(status resume) and is_nil(opts[:evidence]), do: raise("--evidence is required")
    if mode in ~w(fast dev status) and opts[:gate],
      do: raise("--gate is supported by plan, full and resume; #{mode} has a fixed scope")

    evidence =
      opts[:evidence] ||
        Path.join(
          System.tmp_dir!(),
          "med-ecosystem-" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
        )

    repos = Map.new(~w(weld med_ex med_fabric), &{&1, Path.join(root, &1)})

    config = %{
      repos: repos,
      jobs: jobs,
      evidence: Path.expand(evidence),
      opts: opts,
      mode: mode
    }

    required = graph(config) |> Graph.select(opts[:gate]) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    Enum.each(required, fn name ->
      path = Map.fetch!(repos, name)

      unless String.trim(Receipt.git!(path, ["rev-parse", "--is-inside-work-tree"])) == "true",
        do: raise("Expected a checkout at #{path}")
    end)

    config
  end

  defp print_plan(config, opts) do
    if opts[:gate] do
      graph(config)
      |> Graph.select(opts[:gate])
      |> Enum.each(fn {id, _, parents, args} ->
        IO.puts("#{id} follows #{Enum.join(parents, ", ")}: #{inspect(args)}")
      end)
    else
      graph(config)
      |> Graph.select(nil)
      |> Enum.each(fn {id, repo, parents, args} ->
        IO.puts("#{id} (#{repo}) follows #{Enum.join(parents, ", ")}: #{inspect(args)}")
      end)
    end
  end

  defp status(config) do
    unless File.dir?(config.evidence), do: raise("No evidence directory")

    for {id, _, _, _} <- graph(config) do
      path = Path.join(config.evidence, id <> ".receipt.json")

      state =
        cond do
          File.regular?(path) -> "recorded (resume validates)"
          File.regular?(log_path(config, id)) -> "unconfirmed"
          true -> "pending"
        end

      IO.puts("#{id} #{state}")
    end
  end

  defp execute(config, mode, opts) do
    unless File.exists?(config.evidence), do: File.mkdir_p!(config.evidence)
    {:ok, %{type: :directory, mode: access}} = File.lstat(config.evidence)
    unless Bitwise.band(access, 0o077) == 0, do: raise("Use a private evidence directory (0700)")
    IO.puts("Evidence #{config.evidence}")

    if System.get_env("MEDEX_ECOSYSTEM_LOCKED") == config.evidence do
      nodes =
        case mode do
          "dev" -> dev_gates(config, opts)
          "fast" -> Enum.filter(graph(config), &(elem(&1, 0) in ~w(medex-core fabric-projects)))
          _ -> graph(config) |> Graph.select(opts[:gate])
        end

      validate_native_inputs!(config, nodes)
      results = Graph.run(nodes, &run_gate(config, &1, &2))
      unless Graph.successful?(results), do: raise("Qualification failed; independent results retained")
      IO.puts("Verified #{length(nodes)} gates")
    else
      root = Map.fetch!(config.repos, "med_ex")

      common =
        root
        |> Receipt.git!(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        |> String.trim()

      executable = System.find_executable("flock") || raise("flock is required for qualification")
      script = Path.join(__DIR__, "qualify_ecosystem.sh")

      opts =
        List.flatten(
          Enum.map(opts, fn
            {key, true} ->
              ["--" <> (to_string(key) |> String.replace("_", "-"))]

            {key, value} ->
              ["--" <> (to_string(key) |> String.replace("_", "-")), to_string(value)]
          end)
        )

      inherit = [{~c"MEDEX_ECOSYSTEM_LOCKED", String.to_charlist(config.evidence)}]

      args = [
        "-n",
        Path.join(common, "ecosystem-qc.lock"),
        executable,
        "-n",
        Path.join(config.evidence, ".runner.lock"),
        script,
        mode,
        "--evidence",
        config.evidence
        | drop_evidence(opts)
      ]

      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          args: args,
          env: inherit
        ])

      relay(port)
    end
  end

  defp drop_evidence(["--evidence", _ | args]), do: drop_evidence(args)
  defp drop_evidence([arg | args]), do: [arg | drop_evidence(args)]
  defp drop_evidence([]), do: []

  defp relay(port) do
    receive do
      {^port, {:data, bytes}} ->
        IO.write(bytes)
        relay(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        raise "Qualification failed or is locked (exit #{status})"
    end
  end

  defp graph(config) do
    evidence = config.evidence

    matrix =
      if config.opts[:no_cache] or config.opts[:strict],
        do: Path.join(evidence, "medex-cells-" <> run_token()),
        else: Path.join(evidence, "medex-cells")

    prepare = Path.join(evidence, "candidate-prepare-" <> run_token())

    matrix_args =
      cond do
        config.opts[:strict] ->
          ["./build_support/check_consumers.sh", "--strict-full", "--evidence", matrix]

        File.dir?(matrix) and !config.opts[:no_cache] ->
          [
            "./build_support/check_consumers.sh",
            "--resume",
            matrix,
            "--jobs",
            to_string(config.jobs)
          ]

        true ->
          [
            "./build_support/check_consumers.sh",
            "--optimized",
            "--evidence",
            matrix,
            "--jobs",
            to_string(config.jobs)
          ]
      end

    project_script = Path.join(config.repos["med_ex"], "build_support/qualify_projects.sh")

    [
      {"weld-ci", "weld", [], ["bash", "-ec", "mix deps.get --check-locked; mix ci"]},
      {"weld-minimum", "weld", [],
       [project_script, "weld-minimum", Path.join(evidence, "minimum-tooling")]},
      {"medex-short", "med_ex", [], [project_script, "sdk", "--checks-only"]},
      {"fabric-short", "med_fabric", [], [project_script, "fabric", "--checks-only"]},
      {"medex-core", "med_ex", [],
       ["mix", "quality", "--release", "--jobs", to_string(config.jobs)]},
      {"medex-enospc", "med_ex", ~w(medex-core),
       [
         "bash",
         "-ec",
         "MED_EX_ENOSPC_ROOT=\"$1\" mix test core/med_capture/test/storage_enospc_test.exs --include enospc",
         "enospc",
         config.opts[:enospc_root] || ""
       ]},
      {"medex-prepare", "med_ex", ~w(medex-core), ["./build_support/prepare_qualification.sh", prepare]},
      {"medex-matrix", "med_ex", ~w(medex-core medex-prepare), matrix_args},
      {"medex-remote", "med_ex", ~w(medex-prepare),
       [
         "./build_support/qualify_projects.sh",
         "remote",
         Path.join(evidence, "remote-" <> run_token())
       ]},
      {"fabric-projects", "med_fabric", [],
       ["mix", "quality", "--release", "--jobs", to_string(config.jobs)]},
      {"fabric-sources", "med_fabric", ~w(medex-matrix fabric-projects),
       [
         Path.join(config.repos["med_ex"], "build_support/qualify_sources.sh"),
         config.repos["med_ex"],
         Path.join(evidence, "fabric-lanes"),
         "local"
       ]},
      {"fabric-remote", "med_fabric", ~w(medex-remote fabric-projects),
       [
         Path.join(config.repos["med_ex"], "build_support/qualify_sources.sh"),
         config.repos["med_ex"],
         Path.join(evidence, "fabric-remote-lanes"),
         "remote"
       ]},
      {"fabric-native", "med_fabric", ~w(medex-core fabric-projects),
       [
         "./ops/qc_native.sh",
         "--evidence",
         Path.join(evidence, "native-" <> run_token()),
         "--artifacts",
         config.opts[:artifacts] || ""
       ] ++
         if(config.opts[:keep_failure], do: ["--keep-failure"], else: [])},
      {"fabric-soak-off", "med_fabric", ~w(fabric-native medex-enospc),
       [
         "./ops/qc_native.sh",
         "--evidence",
         Path.join(evidence, "soak-off-" <> run_token()),
         "--suite",
         "soak",
         "--preview",
         "off",
         "--seconds",
         "1740",
         "--volume",
         config.opts[:volume] || "",
         "--artifacts",
         config.opts[:artifacts] || ""
       ] ++ if(config.opts[:keep_failure], do: ["--keep-failure"], else: [])},
      {"fabric-soak-isolated", "med_fabric", ~w(fabric-soak-off),
       [
         "./ops/qc_native.sh",
         "--evidence",
         Path.join(evidence, "soak-isolated-" <> run_token()),
         "--suite",
         "soak",
         "--preview",
         "isolated",
         "--seconds",
         "1740",
         "--volume",
         config.opts[:volume] || "",
         "--artifacts",
         config.opts[:artifacts] || ""
       ] ++ if(config.opts[:keep_failure], do: ["--keep-failure"], else: [])}
    ]
  end

  defp validate_native_inputs!(config, nodes) do
    ids = Enum.map(nodes, &elem(&1, 0))

    if Enum.any?(ids, &(&1 in ~w(fabric-native fabric-soak-off fabric-soak-isolated))) do
      path = config.opts[:artifacts]

      unless is_binary(path) and Path.type(path) == :absolute and File.regular?(path),
        do: raise("Native qualification requires --artifacts with an absolute six-tar manifest")

      artifact_identity(config)
    end

    for {gate, option} <- [{"medex-enospc", :enospc_root}, {"fabric-soak-off", :volume}],
        gate in ids do
      path = config.opts[option]

      unless is_binary(path) and Path.type(path) == :absolute and File.dir?(path),
        do:
          raise(
            "#{gate} requires an existing absolute --#{String.replace(to_string(option), "_", "-")} directory"
          )
    end
  end

  defp artifact_identity(config) do
    manifest = config.opts[:artifacts]
    bytes = File.read!(manifest)
    %{"schema" => "medfabric.detached_inputs.v2", "packages" => packages} = JSON.decode!(bytes)

    unless Enum.sort(Map.keys(packages)) ==
             Enum.sort(~w(med_ex med_ex_opus med_ex_rtc mf_exam mf_handheld mf_preview)),
           do: raise("Detached manifest must identify exactly the six public packages")

    files =
      for {name, entry} <- Enum.sort(packages) do
        repository = if name in ~w(med_ex med_ex_opus med_ex_rtc), do: "med_ex", else: "med_fabric"
        checkout = config.repos[repository]
        revision = checkout |> Receipt.git!(["rev-parse", "HEAD"]) |> String.trim()
        unless entry["source_revision"] == revision,
          do: raise("Archive source differs from frozen #{repository} HEAD")
        unless String.trim(Receipt.git!(checkout, ["status", "--porcelain"])) == "",
          do: raise("Archive qualification requires a clean #{repository} checkout")
        archive = Path.expand(Map.fetch!(entry, "archive"), Path.dirname(manifest))
        hash = archive |> File.read!() |> Receipt.sha256()
        unless hash == entry["sha256"], do: raise("Detached archive digest differs for #{name}")

        release =
          if entry["build"] == "weld" do
            entry
            |> Map.fetch!("prepared_release")
            |> Path.expand(Path.dirname(manifest))
            |> File.read!()
            |> Receipt.sha256()
          end

        {name, hash, release}
      end

    {Receipt.sha256(bytes), files}
  end

  defp stable_native_args(["--evidence", _ | rest]), do: stable_native_args(rest)
  defp stable_native_args([arg | rest]), do: [arg | stable_native_args(rest)]
  defp stable_native_args([]), do: []

  defp run_token, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp dev_gates(config, opts) do
    base = opts[:base] || "HEAD"

    for {repo, root} <- Enum.sort(Map.take(config.repos, ~w(med_ex med_fabric))),
        changed = Scope.changed(root, base),
        changed != [],
        {name, args} <- dev_commands(repo, changed, base) do
      IO.puts("#{repo}: #{Enum.join(changed, ", ")}")
      {name, repo, [], args}
    end
  end

  defp dev_commands("med_ex", _, base),
    do: [{"medex-affected", ["./build_support/check_consumers.sh", "--affected", base]}]

  defp dev_commands("med_fabric", changed, _) do
    projects = ~w(core/domain core/store core/interop apps/exam apps/handheld apps/preview)

    path_projects =
      Enum.filter(projects, fn project ->
        Enum.any?(changed, &String.starts_with?(&1, project <> "/"))
      end)

    unknown? =
      Enum.any?(changed, fn path ->
        !Enum.any?(projects, &String.starts_with?(path, &1 <> "/"))
      end)

    expanded =
      Enum.uniq(
        Enum.flat_map(path_projects, fn
          "core/domain" -> ~w(core/domain core/store apps/exam)
          "core/store" -> ~w(core/store apps/exam)
          "core/interop" -> ~w(core/interop apps/exam)
          project -> [project]
        end)
      )

    affected = if unknown?, do: projects, else: expanded

    for project <- affected do
      {"fabric-" <> Path.basename(project),
       [
         "bash",
         "-ec",
         "cd \"$1\"; MIX_ENV=test mix deps.get --check-locked; mix test",
         "qc",
         project
       ]}
    end
  end

  defp run_gate(config, {id, repo, parents, args}, previous) do
    root = Map.fetch!(config.repos, repo)
    dependencies = Map.take(previous, parents)
    input = gate_input(config, root, id, args, dependencies)
    receipt = Path.join(config.evidence, id <> ".receipt.json")
    log = log_path(config, id)
    outputs = gate_outputs(config, root, id, log)

    reuse = if config.opts[:no_cache], do: :miss, else: Receipt.read(receipt, input, outputs)
    reuse =
      case reuse do
        {:ok, details} ->
          if details["generated_inputs"] == generated_inputs(config, id), do: reuse, else: :miss
        :miss -> :miss
      end

    case reuse do
      {:ok, details} ->
        IO.puts("REUSED #{id} (#{details["duration_ms"]} ms, matching input and outputs)")

      :miss ->
        IO.puts("RUN #{id}")
        archive_attempt(config, id)
        started = System.monotonic_time(:millisecond)
        output_directory = output_directory(id, args)
        duration = run_command!(config, id, args, root, log, started)

        if gate_input(config, root, id, args, dependencies) != input do
          raise "Input drifted during #{id}; see #{log}"
        end

        output = File.read!(log)
        tests = test_count(output)

        details = %{
          "duration_ms" => duration,
          "tests" => tests,
          "wall_time_limit_seconds" => wall_time_limit(id),
          "generated_inputs" => generated_inputs(config, id)
        }
        if Enum.any?(details["generated_inputs"], fn {_, value} -> value == "missing" end),
          do: raise("Required generated proof inputs are missing for #{id}")

        if output_directory do
          File.write!(Path.join(config.evidence, id <> ".output"), output_directory)
        end

        Receipt.write!(receipt, input, gate_outputs(config, root, id, log), details)
        IO.puts("PASS #{id} (#{duration} ms, #{tests} reported tests)")
    end

    receipt |> File.read!() |> Receipt.sha256()
  end

  defp output_directory(id, [_, "--evidence", directory | _])
       when id in ~w(fabric-native fabric-soak-off fabric-soak-isolated), do: directory

  defp output_directory("medex-remote", [_, _, directory]), do: directory

  defp output_directory("medex-matrix", [_, mode, directory | _])
       when mode in ["--evidence", "--resume"],
       do: directory

  defp output_directory("medex-matrix", [_, mode, "--evidence", directory | _])
       when mode in ["--optimized", "--strict-full"], do: directory

  defp output_directory(_, _), do: nil

  defp test_count(output) do
    ~r/^Result: (\d+) passed$/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, count] -> String.to_integer(count) end)
    |> Enum.sum()
  end

  defp gate_input(config, root, id, args, parents) do
    stable_args =
      case id do
        "medex-matrix" ->
          [id, config.opts[:strict] == true]

        id when id in ~w(medex-prepare medex-remote) ->
          Enum.take(args, 1)

        id when id in ~w(fabric-native fabric-soak-off fabric-soak-isolated) ->
          stable_native_args(args)

        _ ->
          args
      end

    revision =
      if id in ~w(medex-prepare medex-matrix medex-remote),
        do: Receipt.git!(root, ["rev-parse", "HEAD"])

    remote = if id == "medex-remote", do: verified_remote!(root)

    dependent_sdk =
      if String.starts_with?(id, "fabric-"),
        do: Receipt.source(config.repos["med_ex"])

    hex = System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")
    registry = official_registry(hex)

    Receipt.fingerprint({
      2,
      id,
      source_scope(config, root, id, args),
      Receipt.toolchain(),
      revision,
      remote,
      dependent_sdk,
      if(id in ~w(fabric-native fabric-soak-off fabric-soak-isolated),
        do: artifact_identity(config)
      ),
      registry,
      fixture_identity(config),
      if(String.starts_with?(id, "fabric-"), do: selector_identity(config)),
      if(String.starts_with?(id, "fabric-"),
        do: MedEx.Build.QualificationSources.selected(config.repos["med_fabric"])),
      if(id == "fabric-projects", do: fabric_context_locks(config)),
      executable_identity(id),
      native_inputs(),
      stable_args,
      parents,
      Receipt.source(config.repos["med_ex"], ["build_support"])
    })
  end

  defp source_scope(config, root, id, args) do
    if String.starts_with?(id, "fabric-") and config.mode not in ["fast", "dev"] do
      selector = Path.join(root, ".mix_sources.json")

      unless File.lstat(selector) == {:error, :enoent} do
        raise "Use a default Fabric checkout for ecosystem qualification"
      end
    end

    paths =
      case args do
        ["bash", "-ec", _, "qc", project] ->
          upstream =
            case project do
              "core/store" -> ~w(core/domain)
              "apps/exam" -> ~w(core/domain core/store core/interop)
              _ -> []
            end

          [project, "config", "VERSION", ".tool-versions" | upstream]

        _ ->
          []
      end

    Receipt.source(root, paths)
  end

  defp official_registry(hex) do
    case :file.consult(String.to_charlist(Path.join(hex, "hex.config"))) do
      {:ok, terms} -> {hex, public_coordinates(terms, [])}
      {:error, :enoent} -> {hex, []}
      _ -> raise "Cannot verify Hex configuration"
    end
  end

  defp public_coordinates(terms, path) when is_map(terms),
    do: public_coordinates(Map.to_list(terms), path)

  defp public_coordinates(terms, path) when is_list(terms) do
    Enum.flat_map(terms, fn
      {key, value} when key in [:public_key, "public_key", :url, "url"] ->
        digest =
          if key in [:public_key, "public_key"] do
            Receipt.fingerprint(value)
          else
            uri = value |> to_string() |> URI.parse()
            {uri.scheme, uri.host, uri.port, uri.path}
          end

        [{path ++ [key], digest}]

      {key, value} when is_map(value) or is_list(value) ->
        public_coordinates(value, path ++ [key])

      _ ->
        []
    end)
    |> Enum.sort()
  end

  defp verified_remote!(root) do
    sha = root |> Receipt.git!(["rev-parse", "HEAD"]) |> String.trim()

    remote =
      Receipt.git!(root, [
        "ls-remote",
        "--exit-code",
        "https://github.com/nshkrdotcom/med_ex.git",
        "refs/heads/main",
        "refs/heads/projection/v2/med_ex"
      ])

    rows = remote |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t"))
    refs = Map.new(rows, fn [commit, ref] -> {ref, commit} end)

    unless refs["refs/heads/main"] == sha,
      do: raise("Remote MedEx source differs from local HEAD")

    for app <- ["med_ex"] do
      ref = "refs/heads/projection/v2/#{app}"
      local = root |> Receipt.git!(["rev-parse", ref]) |> String.trim()
      unless refs[ref] == local, do: raise("Remote projection differs: #{ref}")
    end

    refs
  end

  defp gate_outputs(config, root, id, log) do
    extras =
      case id do
        "medex-matrix" ->
          pointer_outputs(config, id, "*.{json,log,pem}")

        "medex-prepare" ->
          Enum.flat_map(["med_ex"], fn app ->
            state = Path.join([root, ".weld", "v2"])
            current = Path.join([state, "current", app])

            case File.read(current) do
              {:ok, bytes} ->
                %{"schema" => "weld.current/2", "artifact" => ^app, "bundle_id" => identity} =
                  JSON.decode!(bytes)

                unless Regex.match?(~r/\A[0-9a-f]{64}\z/, identity),
                  do: raise("Invalid Weld current bundle identity")

                bundle = Path.join([state, "bundles", app, identity])

                [
                  current
                  | Path.wildcard(Path.join(bundle, "**/*"), match_dot: true)
                    |> Enum.filter(&File.regular?/1)
                ]

              _ ->
                [current]
            end
          end)

        id when id in ~w(fabric-native fabric-soak-off fabric-soak-isolated medex-remote) ->
          pointer_outputs(config, id, "**/*.{json,log}")

        _ ->
          []
      end

    Map.new([log | extras], &{&1, &1})
  end

  defp pointer_outputs(config, id, pattern) do
    pointer = Path.join(config.evidence, id <> ".output")

    case File.read(pointer) do
      {:ok, directory} -> [pointer | Path.wildcard(Path.join(directory, pattern))]
      _ -> []
    end
  end

  # Aggregate setup/build/acceptance time, separate from unchanged source lag,
  # startup, media authority and exact 1740-second soak requirements.
  defp wall_time_limit(id) when id in ~w(fabric-native fabric-soak-off fabric-soak-isolated),
    do: 5400

  defp wall_time_limit(_id), do: 2400

  defp run_command!(config, id, args, root, log, started) do
    [program | argv] = args
    executable = Path.join(__DIR__, "qualification_command.sh")

    service =
      System.get_env() |> Map.keys() |> Enum.filter(&String.starts_with?(&1, ["MF_", "PG"]))

    removed =
      Enum.map(
        Enum.uniq(service ++ @outside_services ++ @mix_overrides ++ @hex_overrides),
        &{&1, false}
      )

    env = [
      {"PATH", postgres_path()},
      {"ERL_FLAGS", System.get_env("ERL_FLAGS") || "+S 4:4"},
      {"MED_QC_KEEP_FAILURE", if(config.opts[:keep_failure], do: "1", else: "0")}
      | removed
    ]

    File.open!(log, [:write], fn file ->
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          cd: root,
          env:
            Enum.map(env, fn {key, value} ->
              {String.to_charlist(key),
               if(value == false, do: false, else: String.to_charlist(value))}
            end),
          args: [Integer.to_string(wall_time_limit(id)), program | argv]
        ])

      exit = read_command(port, file, started, started + 15_000)
      if exit != 0, do: raise("Gate exited #{exit}; private log #{log}")
      System.monotonic_time(:millisecond) - started
    end)
  end

  defp read_command(port, file, started, next) do
    now = System.monotonic_time(:millisecond)
    if now >= next, do: IO.puts("Working #{div(now - started, 1000)} s")
    next = if now >= next, do: now + 15_000, else: next

    receive do
      {^port, {:data, bytes}} ->
        IO.binwrite(file, bytes)
        read_command(port, file, started, next)

      {^port, {:exit_status, exit}} ->
        exit
    after
      max(next - now, 0) -> read_command(port, file, started, next)
    end
  end

  defp postgres_path do
    path = System.fetch_env!("PATH")

    case System.find_executable("pg_config") do
      nil -> path
      executable ->
        case System.cmd(executable, ["--bindir"]) do
          {bin, 0} -> String.trim(bin) <> ":" <> path
          _ -> path
        end
    end
  end

  defp archive_attempt(config, id) do
    existing =
      Enum.map([".log", ".receipt.json", ".output"], &Path.join(config.evidence, id <> &1))
      |> Enum.filter(&File.exists?/1)

    if existing != [] do
      directory = Path.join([config.evidence, "attempts", id <> "-" <> run_token()])
      File.mkdir_p!(directory)
      Enum.each(existing, &File.rename!(&1, Path.join(directory, Path.basename(&1))))
    end
  end

  defp fabric_context_locks(config) do
    Mix.start()
    previous = Mix.env()
    projects = [mf_domain: "core/domain", mf_store: "core/store",
      mf_interop: "core/interop", mf_exam: "apps/exam",
      mf_handheld: "apps/handheld", mf_preview: "apps/preview"]

    try do
      for environment <- [:dev, :test, :prod], {app, project} <- projects do
        Mix.env(environment)
        directory = Path.join(config.repos["med_fabric"], project)
        Mix.Project.in_project(app, directory, fn _ ->
          path = Path.expand(Mix.Project.config()[:lockfile] || "mix.lock")
          {project, environment, path, File.read(path)}
        end)
      end
    after
      Mix.env(previous)
    end
  end

  defp generated_inputs(config, id) do
    paths =
      case id do
        "medex-prepare" -> [".weld/v2/live/med_ex"]
        "medex-matrix" -> [".weld/v2/live/med_ex", ".weld/v2/full/med_ex/project"]
        _ -> []
      end

    Map.new(paths, fn relative ->
      path = Path.join(config.repos["med_ex"], relative)
      digest = if File.dir?(path),
        do: MedEx.Build.QualificationSources.path(path), else: "missing"
      {relative, digest}
    end)
  end

  defp selector_identity(config) do
    path = Path.join(config.repos["med_fabric"], ".mix_sources.json")
    case File.lstat(path) do
      {:error, :enoent} -> :default
      {:ok, %{type: :regular}} -> path |> File.read!() |> Receipt.sha256()
      _ -> raise("Source selector must be a regular file")
    end
  end

  defp fixture_identity(config) do
    path = System.get_env("MEDEX_RECEIPT_VECTORS") ||
      Path.join(config.repos["med_ex"], "core/med_core/test/fixtures/receipt_vectors_v2.json")
    {:ok, %{type: :regular}} = File.lstat(path)
    bytes = File.read!(path)
    hash = Receipt.sha256(bytes)
    unless hash == "00e4b87285b26e995f5f0e3bff01c3cce5a8f3c4701e41d9f3981b73a197901b",
      do: raise("Receipt fixture hash differs")
    {Path.expand(path), hash}
  end

  defp native_inputs do
    settings = ~w(CC CXX CPPFLAGS CFLAGS CXXFLAGS LDFLAGS ERL_COMPILER_OPTIONS
      MAKEFLAGS MIX_REBAR3 CMAKE_TOOLCHAIN_FILE PKG_CONFIG_PATH MED_EX_OPUS_TARBALL
      AR RANLIB MED_EX_OPUS_CONFIGURE_FLAGS)
    archive = System.get_env("MED_EX_OPUS_TARBALL")
    {Enum.map(settings, &{&1, System.get_env(&1)}),
      if(archive, do: {archive, File.read(archive)})}
  end

  defp executable_identity(id) do
    tools = ~w(git bash python3 node cc pkg-config mix elixir)
    tools = if String.starts_with?(id, "fabric-"),
      do: tools ++ ~w(pg_config initdb postgres psql chromium chromium-browser turnserver java),
      else: tools

    Enum.map(tools, fn name ->
      case System.find_executable(name) do
        nil -> {name, :unavailable}
        path -> {name, path, path |> File.read!() |> Receipt.sha256()}
      end
    end)
  end

  defp log_path(config, id), do: Path.join(config.evidence, id <> ".log")
end

MedEx.Build.EcosystemQC.main(System.argv())
