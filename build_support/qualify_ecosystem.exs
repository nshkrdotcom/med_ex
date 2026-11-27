Code.require_file("qualification_scope.exs", __DIR__)

defmodule MedEx.Build.EcosystemQC do
  @moduledoc false
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
  Usage: build_support/qualify_ecosystem.sh plan|dev|full|resume|status [options]
    --repos DIR      Parent directory of weld, med_ex and med_fabric
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
  Full qualification expects the current MedEx source to be available remotely
  and Fabric pinned to it. The runner performs no Git push or publication.
  An explicit --gate requires only its participating repositories; the full
  umbrella additionally includes the sibling Weld source project's own CI.
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

      [mode | switches] when mode in ~w(plan dev full resume status) ->
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
      opts: opts
    }

    required =
      if opts[:gate],
        do: graph(config) |> selected(opts[:gate]) |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
        else: Map.keys(repos)

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
      |> selected(opts[:gate])
      |> Enum.each(fn {id, _, parents, args} ->
        IO.puts("#{id} follows #{Enum.join(parents, ", ")}: #{inspect(args)}")
      end)
    else
      dev_gates(config, opts)
      |> Enum.each(fn {id, repo, _, args} ->
        IO.puts("#{id} (#{repo}): #{inspect(args)}")
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
        if mode == "dev" do
          dev_gates(config, opts)
        else
          graph(config) |> selected(opts[:gate])
        end

      validate_native_inputs!(config, nodes)
      Enum.reduce(nodes, %{}, &run_gate(config, &1, &2))
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
      if config.opts[:no_cache],
        do: Path.join(evidence, "medex-cells-" <> run_token()),
        else: Path.join(evidence, "medex-cells")

    prepare = Path.join(evidence, "candidate-prepare-" <> run_token())

    matrix_args =
      cond do
        config.opts[:strict] ->
          ["./build_support/check_consumers.sh", "--strict-full"]

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
      {"medex-core", "med_ex", [], ["./build_support/qualify_projects.sh", "sdk"]},
      {"medex-enospc", "med_ex", ~w(medex-core),
       [
         "bash",
         "-ec",
         "MED_EX_ENOSPC_ROOT=\"$1\" mix test core/med_capture/test/storage_enospc_test.exs --include enospc",
         "enospc",
         config.opts[:enospc_root] || ""
       ]},
      {"medex-prepare", "med_ex", [], ["./build_support/prepare_qualification.sh", prepare]},
      {"medex-matrix", "med_ex", ~w(medex-core medex-prepare), matrix_args},
      {"medex-remote", "med_ex", ~w(medex-prepare),
       [
         "./build_support/qualify_projects.sh",
         "remote",
         Path.join(evidence, "remote-" <> run_token())
       ]},
      {"fabric-projects", "med_fabric", [],
       [Path.join(config.repos["med_ex"], "build_support/qualify_projects.sh"), "fabric"]},
      {"fabric-sources", "med_fabric", ~w(medex-remote fabric-projects),
       [
         Path.join(config.repos["med_ex"], "build_support/qualify_sources.sh"),
         config.repos["med_ex"],
         Path.join(evidence, "fabric-lanes")
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
       ]},
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
       ]}
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

  defp selected(nodes, nil), do: nodes

  defp selected(nodes, id) do
    by_id = Map.new(nodes, &{elem(&1, 0), &1})
    required = prerequisites(by_id, id, MapSet.new())
    Enum.filter(nodes, &MapSet.member?(required, elem(&1, 0)))
  end

  defp prerequisites(nodes, id, seen) do
    {_, _, parents, _} = Map.fetch!(nodes, id)
    Enum.reduce(parents, MapSet.put(seen, id), &prerequisites(nodes, &1, &2))
  end

  defp dev_gates(config, opts) do
    base = opts[:base] || "HEAD"

    for {repo, root} <- Enum.sort(config.repos),
        changed = Scope.changed(root, base),
        changed != [],
        {name, args} <- dev_commands(repo, changed, base) do
      IO.puts("#{repo}: #{Enum.join(changed, ", ")}")
      {name, repo, [], args}
    end
  end

  defp dev_commands("med_ex", _, base),
    do: [{"medex-affected", ["./build_support/check_consumers.sh", "--affected", base]}]

  defp dev_commands("weld", changed, _) do
    docs? = Enum.all?(changed, &(Path.extname(&1) == ".md"))
    args = if docs?, do: ["mix", "docs", "--warnings-as-errors"], else: ["mix", "test"]
    [{"weld-affected", args}]
  end

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

    case reuse do
      {:ok, details} ->
        IO.puts("REUSED #{id} (#{details["duration_ms"]} ms, matching input and outputs)")

      :miss ->
        IO.puts("RUN #{id}")
        File.rm(receipt)
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
          "wall_time_limit_seconds" => wall_time_limit(id)
        }

        if output_directory do
          File.write!(Path.join(config.evidence, id <> ".output"), output_directory)
        end

        Receipt.write!(receipt, input, gate_outputs(config, root, id, log), details)
        IO.puts("PASS #{id} (#{duration} ms, #{tests} reported tests)")
    end

    Map.put(previous, id, receipt |> File.read!() |> Receipt.sha256())
  end

  defp output_directory(id, [_, "--evidence", directory | _])
       when id in ~w(fabric-native fabric-soak-off fabric-soak-isolated), do: directory

  defp output_directory("medex-remote", [_, _, directory]), do: directory

  defp output_directory("medex-matrix", [_, mode, directory | _])
       when mode in ["--evidence", "--resume"],
       do: directory

  defp output_directory("medex-matrix", [_, "--optimized", "--evidence", directory | _]),
    do: directory

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
      if id in ~w(fabric-sources fabric-native fabric-soak-off fabric-soak-isolated),
        do: Receipt.source(config.repos["med_ex"])

    hex = System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")
    registry = official_registry(hex)

    Receipt.fingerprint({
      id,
      source_scope(root, id, args),
      Receipt.toolchain(),
      revision,
      remote,
      dependent_sdk,
      if(id in ~w(fabric-native fabric-soak-off fabric-soak-isolated),
        do: artifact_identity(config)
      ),
      registry,
      stable_args,
      parents,
      Receipt.source(config.repos["med_ex"], ["build_support"])
    })
  end

  defp source_scope(root, id, args) do
    if String.starts_with?(id, "fabric-") do
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
        "refs/heads/projection/med_ex"
      ])

    rows = remote |> String.split("\n", trim: true) |> Enum.map(&String.split(&1, "\t"))
    refs = Map.new(rows, fn [commit, ref] -> {ref, commit} end)

    unless refs["refs/heads/main"] == sha,
      do: raise("Remote MedEx source differs from local HEAD")

    for app <- ["med_ex"] do
      ref = "refs/heads/projection/#{app}"
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
            folder = Path.join([root, ".weld", "releases", app])
            current = Path.join(folder, "CURRENT")

            case File.read(current) do
              {:ok, "weld.release/v1 " <> identity} ->
                bundle = Path.join(folder, String.trim(identity))

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

    case System.cmd("pg_config", ["--bindir"]) do
      {bin, 0} -> String.trim(bin) <> ":" <> path
      _ -> path
    end
  end

  defp log_path(config, id), do: Path.join(config.evidence, id <> ".log")
end

MedEx.Build.EcosystemQC.main(System.argv())
