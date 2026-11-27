Code.require_file("qualification_scope.exs", __DIR__)

defmodule MedEx.ConsumerCheck do
  @moduledoc false

  alias MedEx.Build.QualificationReceipt, as: Receipt
  alias MedEx.Build.QualificationScope, as: Scope

  @repo Path.expand("..", __DIR__)
  @apps [:med_ex, :med_ex_opus, :med_ex_rtc]
  @profiles [
    base: [:med_ex],
    opus: [:med_ex_opus],
    rtc: [:med_ex_rtc],
    both: @apps
  ]
  @transports ~w(direct live full prepared git tracked archive registry)
  @switches [
    quick: :boolean,
    full: :boolean,
    strict_full: :boolean,
    optimized: :boolean,
    functional: :boolean,
    compatibility: :boolean,
    affected: :string,
    resume: :string,
    plan: :boolean,
    jobs: :integer,
    release_extras: :string,
    registry: :boolean,
    registry_lock: :keep,
    prepared_packages: :boolean,
    projected_packages: :boolean,
    weld_invoker: :string,
    transport: :string,
    profile: :string,
    git_url: :string,
    git_ref: :string,
    evidence: :string,
    help: :boolean
  ]
  @mix_paths ~w(MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE MIX_EXS MIX_TARGET)
  @hex_overrides ~w(HEX_API_KEY HEX_TOKEN HEX_API_URL HEX_MIRROR HEX_TRUSTED_MIRROR
                    HEX_MIRROR_URL HEX_TRUSTED_MIRROR_URL HEX_OFFLINE
                    HEX_UNSAFE_HTTPS HEX_UNSAFE_REGISTRY HEX_NO_VERIFY_REPO_ORIGIN
                    HEX_HTTP_PROXY HEX_HTTPS_PROXY HTTP_PROXY HTTPS_PROXY http_proxy https_proxy)
  @usage """
  Usage: build_support/check_consumers.sh [--quick | --full | --transport TRANSPORT]
                                        [--profile base|opus|rtc|both]
                                        [--git-url URL --git-ref EXACT_SHA]
                                        [--evidence NEW_DIRECTORY]
         build_support/check_consumers.sh --registry [--evidence NEW_DIRECTORY] -- COMMAND [ARGS]

  Transports: #{Enum.join(@transports, ", ")}
  Quick (default): all four direct source profiles.
  Release extras: --release-extras PREVIOUS_MATRIX_EVIDENCE
  Resume standalone suites and the combined release.
  Full: base Weld lanes and independent direct/Git/archive/registry provider suites.
  Full expects base live/full/prepared candidates and a committed source checkout.
  Only projection/med_ex is tracked; providers always use native Mix projects.
  --strict-full is an alias for the original exhaustive --full.
  --optimized --evidence DIR runs the same supported lanes and release extras.
  Equivalent cells prove their own lock, installed modules and smoke behavior,
  then reuse provider tests from the direct profile. Distinct inputs run the full suite.
  --resume DIR validates retained cell receipts and reruns missing cells.
  --jobs N runs up to four isolated optimized cells at a time (default 1).
  --compatibility --transport TRANSPORT --evidence DIR compares a single transport to direct.
  --functional runs the canonical direct profiles and the base architecture checks.
  --affected BASE selects downstream profiles and checks. Add --plan to inspect scope.
  Registry builds direct-source packages and runs COMMAND with an isolated signed Hex repo.
  Pass --projected-packages to refresh and build full projections of the clean current
  revision before preparing releases. It runs Weld from tools/maintainer; use
  --weld-invoker ABSOLUTE_DIRECTORY for an already configured candidate Weld checkout.
  Use --prepared-packages to read verified CURRENT
  archives afterward. These selections are mutually exclusive. Repeat --registry-lock
  PATH to include genuine third-party dependencies from consumer lockfiles.
  """

  def main(argv) do
    {flags, command} = Enum.split_while(argv, &(&1 != "--"))

    case OptionParser.parse(flags, strict: @switches) do
      {[help: true], [], []} -> IO.puts(@usage)
      {opts, [], []} -> run(opts, Enum.drop(command, 1))
      _ -> raise ArgumentError, @usage
    end
  end

  defp run(opts, command) do
    validate_options!(opts, command)
    ensure_toolchain!()

    if opts[:plan] do
      plan(opts)
    else
      run_checks(opts, command)
    end
  end

  defp run_checks(opts, command) do
    stage = temporary_directory!()

    try do
      version = @repo |> Path.join("VERSION") |> File.read!() |> String.trim()

      versions =
        Map.new(direct(), fn {app, opts} ->
          value = opts[:path] |> Path.join("VERSION") |> File.read!() |> String.trim()
          {:ok, _} = Version.parse(value)
          {app, value}
        end)

      ctx = %{
        stage: stage,
        version: version,
        versions: versions,
        evidence: opts[:resume] || evidence_directory!(opts[:evidence]),
        hex_home: Path.join(stage, "official-hex"),
        git_url: opts[:git_url],
        git_ref: opts[:git_ref],
        jobs: opts[:jobs] || 1,
        optimized: opts[:optimized] || opts[:resume] != nil
      }

      cond do
        opts[:registry] ->
          archives =
            cond do
              opts[:prepared_packages] -> prepared_archives!(ctx)
              opts[:projected_packages] -> projected_archives!(ctx, opts[:weld_invoker])
              true -> projected_archives!(ctx, opts[:weld_invoker])
            end

          with_registry(
            ctx,
            archives,
            fn env, _packages ->
              [program | args] = command
              IO.write(command!(ctx, "registry-command", program, args, File.cwd!(), env))
            end,
            Keyword.get_values(opts, :registry_lock)
          )

        opts[:release_extras] ->
          release_extras!(ctx, opts[:release_extras])

        ctx.optimized ->
          run_optimized!(ctx)

        opts[:full] || opts[:strict_full] ->
          full_matrix!(ctx)

        opts[:compatibility] ->
          input = source_input()
          ctx = Map.merge(ctx, %{optimized: true, source_input: input})
          selected = Keyword.take(@profiles, matching_profiles(opts))
          optimized_cells!(ctx, [{"direct", direct()}], nil, %{}, selected)
          compatibility!(ctx, opts[:transport], selected)

          unless source_input() == input,
            do: raise("Source or toolchain drifted during compatibility checks")

        opts[:functional] ->
          canonical!(ctx, @profiles, true)

        opts[:affected] ->
          affected!(ctx, opts[:affected])

        true ->
          name = opts[:transport] || "direct"

          profiles =
            Enum.filter(@profiles, fn {id, _} ->
              !opts[:profile] or to_string(id) == opts[:profile]
            end)

          single_transport!(ctx, name, profiles)
      end
    after
      File.rm_rf!(stage)
    end
  end

  @doc false
  def validate_options!(opts, command) do
    modes =
      Enum.count(
        [
          opts[:quick],
          opts[:full],
          opts[:strict_full],
          opts[:optimized],
          opts[:functional],
          opts[:affected],
          opts[:transport],
          opts[:registry],
          opts[:release_extras],
          opts[:resume]
        ],
        & &1
      )

    unless modes <= 1 and (opts[:transport] || "direct") in @transports and
             (!opts[:profile] or opts[:profile] in Enum.map(Keyword.keys(@profiles), &to_string/1)) and
             (!opts[:profile] or
                !(opts[:full] || opts[:strict_full] || opts[:optimized] ||
                    opts[:resume] || opts[:registry] || opts[:release_extras] || opts[:functional] ||
                    opts[:affected])) and
             (!opts[:jobs] or
                (opts[:jobs] in 1..4 and (opts[:optimized] || not is_nil(opts[:resume])))) and
             ((!(opts[:optimized] || opts[:compatibility]) or opts[:plan]) ||
                not is_nil(opts[:evidence])) and
             (!opts[:compatibility] or
                (is_binary(opts[:transport]) and opts[:transport] != "direct")) and
             (!opts[:resume] or (is_nil(opts[:evidence]) and File.dir?(opts[:resume]))) and
             (!opts[:plan] or
                Enum.any?(
                  Keyword.take(opts, [:affected, :optimized, :full, :strict_full, :resume]),
                  &elem(&1, 1)
                )) and
             (!(opts[:prepared_packages] || opts[:projected_packages] || opts[:registry_lock]) or
                opts[:registry] == true) and
             !(opts[:prepared_packages] && opts[:projected_packages]) and
             (is_nil(opts[:weld_invoker]) or
                (opts[:projected_packages] == true and
                   Path.type(opts[:weld_invoker]) == :absolute and
                   File.dir?(opts[:weld_invoker]) and
                   File.regular?(Path.join(opts[:weld_invoker], "mix.exs")))) and
             opts[:registry] == true == (command != []) and
             is_nil(opts[:git_url]) == is_nil(opts[:git_ref]) and
             (!opts[:git_ref] or Regex.match?(~r/\A[0-9a-f]{40}\z/, opts[:git_ref])) do
      raise ArgumentError, @usage
    end

    :ok
  end

  defp plan(opts) do
    description =
      if base = opts[:affected] do
        paths = Scope.changed(@repo, base)
        %{changed: paths, work: Scope.medex(paths)}
      else
        %{transports: @transports, profiles: Keyword.keys(@profiles), release_extras: true}
      end

    IO.puts(JSON.encode!(description))
  end

  defp canonical!(ctx, profiles, architecture?) do
    if architecture? do
      command!(ctx, "architecture", Path.join(__DIR__, "check_architecture.sh"), [], @repo)

      command!(
        ctx,
        "browser-assets",
        "node",
        ["--test" | Path.wildcard(Path.join(@repo, "test/*.mjs"))],
        @repo
      )
    end

    consumer_matrix!(ctx, "direct", direct(), profiles)
  end

  defp affected!(ctx, base) do
    paths = Scope.changed(@repo, base)
    work = Scope.medex(paths)
    IO.puts(JSON.encode!(%{changed: paths, work: work}))
    profiles = Keyword.take(@profiles, work.profiles)
    canonical!(ctx, profiles, work.architecture)

    if work.docs,
      do: mix!(ctx, "affected-docs", @repo, ["docs", "--warnings-as-errors"], [], "dev")

    if work.packaging, do: build_family!(ctx, direct(), "affected")
  end

  defp source_input do
    Receipt.fingerprint({Receipt.source(@repo), Receipt.toolchain(), System.get_env("PATH")})
  end

  defp run_optimized!(ctx) do
    identity = source_input()

    evidence = Path.expand(ctx.evidence)
    {:ok, %{type: :directory, mode: mode}} = File.lstat(evidence)
    if Bitwise.band(mode, 0o077) != 0, do: raise("Use a private qualification evidence directory")
    executable = System.find_executable("flock") || raise "Optimized qualification needs flock"

    if System.get_env("MEDEX_CONSUMER_LOCKED") != evidence do
      args =
        [
          "--exclusive",
          "--nonblock",
          Path.join(evidence, ".qualification.lock"),
          Path.join(@repo, "build_support/check_consumers.sh"),
          "--resume",
          evidence,
          "--jobs",
          Integer.to_string(ctx.jobs)
        ] ++ if(ctx.git_url, do: ["--git-url", ctx.git_url, "--git-ref", ctx.git_ref], else: [])

      env = [{~c"MEDEX_CONSUMER_LOCKED", String.to_charlist(evidence)}]

      port =
        Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: args, env: env])

      relay!(port)
    else
      ctx = Map.merge(ctx, %{evidence: evidence, source_input: identity})
      full_matrix!(ctx)

      unless source_input() == identity,
        do: raise("Source or toolchain drifted during qualification")
    end
  end

  defp relay!(port) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        relay!(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        raise "optimized qualification failed with exit #{status} (or evidence directory is in use)"
    end
  end

  defp ensure_toolchain! do
    unless Version.match?(System.version(), "~> 1.20") and System.find_executable("mix") do
      raise "MedEx consumer checks require Elixir and Mix 1.20 or later"
    end
  end

  defp full_matrix!(ctx) do
    source_revision = clean_source_revision!(ctx, "start")
    live = projected!(ctx, "live")
    full = projected!(ctx, "full")
    prepared = projected!(ctx, "prepared", source_revision)
    git = git_family!(ctx, :root)
    tracked = git_family!(ctx, :tracked)
    verify_git_checkpoint!(ctx, source_revision, prepared, tracked)
    archives = build_family!(ctx, full, "projected")

    transports = [
      {"direct", direct()},
      {"live", live},
      {"full", full},
      {"prepared", prepared},
      {"git", git},
      {"tracked", tracked},
      {"archive", archive_paths(ctx, archives)}
    ]

    if ctx.optimized do
      official_bootstrap!(ctx)
      optimized_cells!(ctx, [hd(transports)], nil, %{})
      optimized_cells!(ctx, tl(transports), nil, %{})
    else
      for {name, specs} <- transports, do: consumer_matrix!(ctx, name, specs, @profiles)
    end

    with_registry(ctx, archives, fn env, packages ->
      if ctx.optimized do
        optimized_cells!(ctx, [{"registry", registry_specs()}], env, packages)
        work = Path.join([ctx.stage, "consumers", "registry-both"])
        create_consumer!(ctx, work, @apps, registry_specs(), false)
      else
        consumer_matrix!(ctx, "registry", registry_specs(), @profiles, env, packages)
      end

      extra!(ctx, "standalone", packages, env, standalone_logs(), fn ->
        standalone_extensions!(ctx, full, env, packages)
      end)

      extra!(ctx, "combined", packages, env, ~w(combined-release-resolve combined-release), fn ->
        verify_combined_release!(ctx, env, packages)
      end)
    end)

    verify_source_revision!(ctx, source_revision, "finish")
  end

  defp standalone_logs do
    for app <- @apps -- [:med_ex],
        step <- ~w(resolve test doc-deps docs),
        do: "#{app}-standalone-#{step}"
  end

  defp extra!(%{optimized: false}, _, _, _, _, action), do: action.()

  defp extra!(ctx, name, archives, env, logs, action) do
    files = Map.new(logs, &{&1, Path.join(ctx.evidence, &1 <> ".log")})

    lock = Path.join([ctx.stage, "official-resolution", "mix.lock"]) |> File.read!() |> digest()

    trust =
      if env,
        do: Path.join([ctx.stage, "registry", "public_key"]) |> File.read!() |> digest(),
        else: "official-hexpm"

    key =
      Receipt.fingerprint(
        {ctx.source_input, name, Map.new(archives, fn {app, a} -> {app, a.sha256} end), lock,
         trust}
      )

    path = Path.join(ctx.evidence, "extra-#{name}.receipt.json")

    case Receipt.read(path, key, files) do
      {:ok, _} ->
        IO.puts("REUSED #{name} extras (matching inputs and outputs)")

      :miss ->
        action.()
        Receipt.write!(path, key, files, %{"extras" => name})
    end
  end

  defp release_extras!(ctx, previous) do
    revision = git_revision!(ctx, "resume-source-head", @repo, "HEAD")

    for phase <- ["start", "checkpoint"] do
      [_, recorded] =
        previous
        |> Path.join("git-source-head-#{phase}.log")
        |> File.read!()
        |> String.split("\n", parts: 2)

      unless String.trim(recorded) == revision do
        raise "Previous matrix source revision differs"
      end
    end

    for transport <- @transports, {profile, _} <- supported_profiles(transport, @profiles) do
      label = "#{transport}-#{profile}-test"

      summary =
        previous
        |> Path.join("#{label}.log")
        |> File.read!()
        |> String.split("\n", parts: 2)
        |> hd()

      unless String.ends_with?(summary, "exit 0)") do
        raise "Missing successful matrix evidence for #{label}"
      end
    end

    full = projected!(ctx, "full")
    archives = build_family!(ctx, full, "projected")

    for app <- @apps do
      recorded = read_json!(Path.join(previous, "projected-#{app}-hex.json"))

      unless recorded["sha256"] == archives[app].sha256 do
        raise "Projected archive changed since the matrix: #{app}"
      end
    end

    IO.puts("Confirmed supported source lanes and identical exact archives")

    with_registry(ctx, archives, fn env, packages ->
      standalone_extensions!(ctx, full, env, packages)

      work = Path.join([ctx.stage, "consumers", "registry-both"])
      create_consumer!(ctx, work, @apps, registry_specs(), false)

      verify_combined_release!(ctx, env, packages)
    end)
  end

  defp verify_git_checkpoint!(ctx, revision, prepared, tracked) do
    bare = tracked[:med_ex][:git]

    unless git_revision!(ctx, "git-snapshot-head", bare, "HEAD") == revision do
      raise "The source revision changed while cloning the candidate Git snapshot"
    end

    for app <- [:med_ex] do
      tree =
        git!(
          ctx,
          "tracked-#{app}-tree",
          ["ls-tree", "-r", "-z", "--full-tree", tracked[app][:ref]],
          bare
        )

      verify_tracked_tree!(prepared[app][:path], tree)
    end

    verify_source_revision!(ctx, revision, "checkpoint")
  end

  defp verify_source_revision!(ctx, expected, phase) do
    unless clean_source_revision!(ctx, phase) == expected do
      raise "The source revision changed during the full matrix"
    end
  end

  defp clean_source_revision!(ctx, phase) do
    status =
      git!(
        ctx,
        "git-source-status-#{phase}",
        ["status", "--porcelain", "--untracked-files=normal"],
        @repo
      )

    unless status == "", do: raise("Commit the candidate source before running the full matrix")
    git_revision!(ctx, "git-source-head-#{phase}", @repo, "HEAD")
  end

  defp matching_profiles(opts) do
    for {name, _} <- @profiles,
        is_nil(opts[:profile]) or to_string(name) == opts[:profile],
        do: name
  end

  defp compatibility!(ctx, "registry", profiles) do
    with_registry(ctx, build_family!(ctx, direct(), "registry"), fn env, packages ->
      optimized_cells!(ctx, [{"registry", registry_specs()}], env, packages, profiles)
    end)
  end

  defp compatibility!(ctx, name, profiles) do
    optimized_cells!(ctx, [{name, transport_specs!(ctx, name)}], nil, %{}, profiles)
  end

  defp single_transport!(ctx, "registry", profiles) do
    with_registry(ctx, build_family!(ctx, direct(), "registry"), fn env, packages ->
      consumer_matrix!(ctx, "registry", registry_specs(), profiles, env, packages)
    end)
  end

  defp single_transport!(ctx, name, profiles) do
    consumer_matrix!(ctx, name, transport_specs!(ctx, name), profiles)
  end

  defp transport_specs!(ctx, name) do
    case name do
      "direct" -> direct()
      "git" -> git_family!(ctx, :root)
      "tracked" -> git_family!(ctx, :tracked)
      "archive" -> archive_paths(ctx, build_family!(ctx, direct(), "direct"))
      projected -> projected!(ctx, projected)
    end
  end

  defp direct do
    Map.new(@apps, fn app ->
      path = if app == :med_ex, do: @repo, else: Path.join([@repo, "extensions", to_string(app)])
      {app, [path: path]}
    end)
  end

  defp projected!(ctx, kind, revision \\ nil) do
    {source, integrity} = projection_path!(:med_ex, kind, revision)
    marker = read_json!(Path.join(source, "weld.provenance.json"))
    expected = if kind == "live", do: "live", else: "full"

    unless marker["kind"] == expected and marker["artifact"] == "med_ex",
      do: raise("Unexpected base Weld provenance")

    path = if kind == "live", do: source, else: detach!(ctx, source, "#{kind}-med_ex")
    if integrity, do: verify_prepared_tree!(path, integrity)
    if kind == "full" and revision, do: verify_full_projection!(path, :med_ex, revision)
    Map.put(direct(), :med_ex, path: path)
  end

  defp projection_path!(app, "live", _revision),
    do: {Path.join([@repo, ".weld", "live", to_string(app)]), nil}

  defp projection_path!(app, "full", _revision),
    do: {Path.join([@repo, ".weld", "full", to_string(app), "project"]), nil}

  defp projection_path!(app, "prepared", revision) do
    releases = Path.join([@repo, ".weld", "releases", to_string(app)])
    pointer = File.read!(Path.join(releases, "CURRENT"))

    [_, identity] =
      Regex.run(~r/\Aweld\.release\/v1 ([0-9a-f]{64})\n?\z/, pointer) ||
        raise("Invalid prepared pointer for #{app}")

    bundle = Path.join(releases, identity)
    metadata = read_json!(Path.join(bundle, "release.json"))
    path = Path.join(bundle, "project")

    unless metadata["identity"] == identity and metadata["artifact"] == to_string(app) and
             is_map(metadata["integrity"]),
           do: raise("Invalid prepared identity for #{app}")

    if revision && metadata["source_revision"] != revision do
      raise "Prepared release for #{app} does not match source revision #{revision}"
    end

    verify_prepared_tree!(path, metadata["integrity"])
    {path, metadata["integrity"]}
  end

  @doc false
  def verify_full_projection!(root, app, revision) do
    marker = read_json!(Path.join(root, "weld.provenance.json"))
    lock = read_json!(Path.join(root, "projection.lock.json"))
    artifact = to_string(app)

    unless marker["schema"] == "weld.projection/v1" and marker["kind"] == "full" and
             marker["artifact"] == artifact and get_in(lock, ["artifact", "id"]) == artifact do
      raise "Unexpected full projection provenance for #{app}"
    end

    unless get_in(lock, ["projection", "git_revision"]) == revision,
      do:
        raise("Full projection for #{app} does not match the current source revision; refresh it")

    content =
      for {relative, path, mode} <- project_files!(root),
          relative not in ~w(weld.provenance.json projection.lock.json),
          do:
            :erlang.term_to_binary(
              {relative, Bitwise.band(mode, 0o111), digest(File.read!(path))}
            )

    unless marker["artifact_id"] == digest(content),
      do: raise("Full projection portable content changed for #{app}; refresh it")

    :ok
  end

  @doc false
  def verify_prepared_tree!(root, integrity) do
    entries =
      Enum.map(project_files!(root), fn {relative, path, mode} ->
        {relative, Bitwise.band(mode, 0o111), digest(File.read!(path))}
      end)

    tree = Enum.map_join(entries, "\n", fn {relative, _mode, hash} -> "#{relative}:#{hash}" end)
    content = Enum.map(entries, &:erlang.term_to_binary/1)

    unless integrity["project_sha256"] == digest(tree) and
             integrity["project_identity"] == digest(content),
           do: raise("Invalid prepared project integrity at #{root}")

    :ok
  end

  @doc false
  def verify_tracked_tree!(root, tree) do
    tracked =
      tree
      |> :binary.split(<<0>>, [:global, :trim])
      |> Map.new(fn entry ->
        [header, relative] = :binary.split(entry, "\t")

        case String.split(header, " ") do
          [mode, "blob", oid] when mode in ["100644", "100755"] -> {relative, {mode, oid}}
          _ -> raise "Unsafe tracked projection tree entry #{inspect(relative)}"
        end
      end)

    prepared =
      Map.new(project_files!(root), fn {relative, path, mode} ->
        git_mode = if Bitwise.band(mode, 0o100) == 0, do: "100644", else: "100755"
        bytes = File.read!(path)
        blob = ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes]
        oid = :sha |> :crypto.hash(blob) |> Base.encode16(case: :lower)
        {relative, {git_mode, oid}}
      end)

    unless tracked == prepared do
      raise "Tracked projection tree does not match the prepared project at #{root}"
    end

    :ok
  end

  defp project_files!(root) do
    unless File.lstat!(root).type == :directory, do: raise("Unsafe prepared project #{root}")

    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      case File.lstat!(path) do
        %{type: :directory} -> []
        %{type: :regular, mode: mode} -> [{Path.relative_to(path, root), path, mode}]
        _ -> raise "Unsafe prepared project input #{path}"
      end
    end)
  end

  defp detach!(ctx, source, label) do
    unless File.lstat!(source).type == :directory,
      do: raise("Expected regular project at #{source}")

    target = Path.join([ctx.stage, "detached", label])
    reports = ~w(weld.provenance.json projection.lock.json)
    lock = read_json!(Path.join(source, "projection.lock.json"))
    inventory = get_in(lock, ["projection", "verification_files"])

    unless is_list(inventory) and "mix.exs" in inventory do
      raise "Missing verification inventory at #{source}"
    end

    # The verification result owns these files. Build caches and unrelated
    # generated outputs are outside this copy, even if present in the source.
    lockfile = if File.regular?(Path.join(source, "mix.lock")), do: ["mix.lock"], else: []

    for relative <- Enum.uniq(inventory ++ reports ++ lockfile) do
      original = regular_file!(source, relative)
      destination = Path.join(target, relative)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(original, destination)
      File.chmod!(destination, Bitwise.band(File.stat!(original).mode, 0o777))
    end

    target
  end

  defp git_family!(ctx, :root) when is_binary(ctx.git_url) do
    Map.new(@apps, fn app ->
      options = [git: ctx.git_url, ref: ctx.git_ref]
      options = if app == :med_ex, do: options, else: options ++ [subdir: "extensions/#{app}"]
      {app, options}
    end)
  end

  defp git_family!(ctx, mode) do
    bare = Path.join(ctx.stage, "source.git")

    unless File.dir?(bare) do
      git!(ctx, "git-source-commit", ["rev-parse", "--verify", "HEAD^{commit}"], @repo)
      git!(ctx, "git-bare-clone", ["clone", "--bare", "--no-hardlinks", @repo, bare], ctx.stage)
    end

    Map.new(@apps, fn app ->
      ref =
        if mode == :tracked and app == :med_ex, do: "refs/heads/projection/med_ex", else: "HEAD"

      sha = git_revision!(ctx, "#{mode}-#{app}-sha", bare, ref)
      options = [git: bare, ref: sha]

      options =
        if app != :med_ex,
          do: options ++ [subdir: "extensions/#{app}"],
          else: options

      {app, options}
    end)
  end

  defp git_revision!(ctx, label, repo, ref) do
    sha = git!(ctx, label, ["rev-parse", "--verify", "#{ref}^{commit}"], repo) |> String.trim()
    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, sha), do: raise("Invalid Git revision for #{ref}")
    sha
  end

  defp registry_specs, do: Map.new(@apps, &{&1, []})

  defp consumer_matrix!(ctx, name, specs, profiles, env \\ nil, archives \\ %{}) do
    env = env || official_env(ctx)

    for {profile, apps} <- supported_profiles(name, profiles),
        do: run_cell!(ctx, name, specs, profile, apps, env, archives)
  end

  defp supported_profiles(name, profiles) when name in ["live", "full", "prepared", "tracked"],
    do: Keyword.take(profiles, [:base])

  defp supported_profiles(_name, profiles), do: profiles

  defp optimized_cells!(ctx, transports, env, archives, profiles \\ @profiles) do
    cells =
      for {name, specs} <- transports, {profile, apps} <- supported_profiles(name, profiles) do
        {name, specs, profile, apps, cell_input(ctx, name, specs, profile, apps, env, archives)}
      end

    cells
    |> Task.async_stream(
      fn {name, specs, profile, apps, input} ->
        label = "#{name}-#{profile}"
        receipt = Path.join(ctx.evidence, "#{label}.receipt.json")
        files = cell_outputs(ctx, label)
        canonical = canonical_proof(ctx, name, profile)

        case Receipt.read(receipt, input, files) do
          {:ok, %{"functional_source" => "own"} = details} ->
            IO.puts("REUSED #{label} (#{details["tests"]} tests, verified inputs and outputs)")

          {:ok, %{"functional_source" => ^canonical} = details} when not is_nil(canonical) ->
            IO.puts("REUSED #{label} (#{details["tests"]} tests, verified canonical evidence)")

          _ ->
            private_env = private_hex!(ctx, label, env)
            details = run_cell!(ctx, name, specs, profile, apps, private_env, archives)

            unless input == cell_input(ctx, name, specs, profile, apps, env, archives),
              do: raise("Input changed during #{label}")

            Receipt.write!(receipt, input, files, details)
        end
      end,
      max_concurrency: ctx.jobs,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.each(fn {:ok, _result} -> :ok end)
  end

  defp private_hex!(ctx, label, nil) do
    copy = Path.join(ctx.stage, "hex-#{label}")
    if File.dir?(ctx.hex_home), do: File.cp_r!(ctx.hex_home, copy)
    official_env(%{ctx | hex_home: copy})
  end

  defp private_hex!(ctx, label, env) do
    {"HEX_HOME", seed} = List.keyfind(env, "HEX_HOME", 0)
    copy = Path.join(ctx.stage, "hex-#{label}")
    File.cp_r!(seed, copy)
    List.keyreplace(env, "HEX_HOME", 0, {"HEX_HOME", copy})
  end

  defp cell_outputs(ctx, label) do
    names = Enum.map(~w(resolve tree compile test inputs lock modules), &{"#{label}-#{&1}", &1})

    Map.new(names, fn {key, step} ->
      suffix = if step in ~w(inputs lock modules), do: ".json", else: ".log"
      {step, Path.join(ctx.evidence, key <> suffix)}
    end)
  end

  defp cell_input(ctx, name, specs, profile, apps, env, archives) do
    selection =
      for app <- apps do
        case Map.fetch!(specs, app) do
          [path: path] -> {app, path_fingerprint(path)}
          [] -> {app, archives[app].sha256}
          options -> {app, Keyword.update!(options, :git, &normalize_git(&1, ctx.stage))}
        end
      end

    trust =
      if env do
        key = Path.join([ctx.stage, "registry", "public_key"])
        key |> File.read!() |> digest()
      else
        "official-hexpm"
      end

    Receipt.fingerprint({ctx.source_input, name, profile, selection, trust})
  end

  defp normalize_git(url, stage) do
    if String.starts_with?(url, stage <> "/"), do: Path.relative_to(url, stage), else: url
  end

  @doc false
  def path_fingerprint(path) do
    patterns =
      ~w(mix.exs mix.lock VERSION Makefile c_src/**/* lib/**/* components/**/* core/**/lib/**/*
                  config/**/* priv/**/* build_support/composition.exs projection.lock.json
                  weld.provenance.json)

    for pattern <- patterns,
        file <- Path.wildcard(Path.join(path, pattern), match_dot: true),
        File.regular?(file) do
      {Path.relative_to(file, path), file |> File.read!() |> digest()}
    end
    |> Enum.sort()
    |> Receipt.fingerprint()
  end

  defp canonical_proof(_ctx, "direct", _profile), do: nil

  defp canonical_proof(ctx, _name, profile) do
    path = Path.join(ctx.evidence, "direct-#{profile}.receipt.json")
    if File.regular?(path), do: path |> File.read!() |> digest()
  end

  defp run_cell!(ctx, name, specs, profile, apps, env, archives) do
    label = "#{name}-#{profile}"
    work = Path.join([ctx.stage, "consumers", label])
    create_consumer!(ctx, work, apps, specs, name != "registry")
    stage_tests!(work, apps)
    inventory = Path.join(work, "modules.json")
    outputs = if ctx.optimized, do: cell_outputs(ctx, label), else: %{}

    test_env =
      [
        {"SDK_PROFILE", to_string(profile)},
        {"SDK_TRANSPORT", name},
        {"SDK_SOURCE_ROOT", @repo},
        {"SDK_MODULE_INVENTORY", inventory},
        {"SDK_EFFECTIVE_INPUTS", outputs["inputs"]}
      ] ++ env

    mix!(ctx, "#{label}-resolve", work, ["deps.get"], test_env)
    assert_lock!(ctx, work, apps, specs, archives)
    mix!(ctx, "#{label}-tree", work, ["deps.tree"], test_env)
    mix!(ctx, "#{label}-compile", work, ["compile", "--warnings-as-errors"], test_env)

    if ctx.optimized && name != "direct" do
      output =
        mix!(ctx, "#{label}-smoke", work, ["test", "test/consumer_smoke_test.exs"], test_env)

      if read_json!(outputs["inputs"]) ==
           read_json!(cell_outputs(ctx, "direct-#{profile}")["inputs"]) do
        File.cp!(Path.join(ctx.evidence, "#{label}-smoke.log"), outputs["test"])
        [_, count] = Regex.run(~r/^Result: (\d+) passed$/m, output)

        finish_cell!(
          ctx,
          label,
          profile,
          work,
          inventory,
          outputs,
          canonical_proof(ctx, name, profile),
          String.to_integer(count)
        )
      else
        IO.puts("DISTINCT #{label} (effective inputs differ, running its behavioral suite)")
        full_cell!(ctx, label, profile, work, inventory, outputs, test_env)
      end
    else
      full_cell!(ctx, label, profile, work, inventory, outputs, test_env)
    end
  end

  defp full_cell!(ctx, label, profile, work, inventory, outputs, env) do
    output = mix!(ctx, "#{label}-test", work, ["test"], env)

    if ctx.optimized do
      [_, count] = Regex.run(~r/^Result: (\d+) passed$/m, output)
      finish_cell!(ctx, label, profile, work, inventory, outputs, "own", String.to_integer(count))
    else
      compare_modules!(ctx, profile, inventory)
    end
  end

  defp finish_cell!(ctx, label, profile, work, inventory, outputs, source, count) do
    File.cp!(inventory, outputs["modules"])
    lock = read_lock(Path.join(work, "mix.lock"))
    File.write!(outputs["lock"], JSON.encode!(Map.new(lock, fn {k, v} -> {k, inspect(v)} end)))
    reference = cell_outputs(ctx, "direct-#{profile}")["modules"]

    unless read_json!(reference) == read_json!(inventory),
      do: raise("Module inventory differs for #{label}")

    %{"tests" => count, "functional_source" => source}
  end

  defp create_consumer!(ctx, work, apps, specs, override?, requirements \\ %{}) do
    File.mkdir_p!(work)

    deps =
      for app <- apps do
        options = Map.fetch!(specs, app)
        options = if app == :med_ex and override?, do: options ++ [override: true], else: options
        requirement = Map.get(requirements, app, "~> #{ctx.versions[app]}")
        if options == [], do: {app, requirement}, else: {app, requirement, options}
      end

    File.write!(Path.join(work, "mix.exs"), """
    defmodule FreshConsumer.MixProject do
      use Mix.Project
      def project, do: [app: :fresh_consumer, version: "0.0.0", elixir: "~> 1.20", deps: #{inspect(deps)}]
    end
    """)
  end

  defp stage_tests!(work, apps) do
    tests = Path.join(work, "test")
    File.mkdir_p!(tests)

    File.cp!(
      Path.join(__DIR__, "consumer_smoke.exs"),
      Path.join(tests, "consumer_smoke_test.exs")
    )

    File.cp!(Path.join(@repo, "tools/cli_recorder.exs"), Path.join(tests, "cli_recorder.exs"))

    helpers =
      for app <- apps -- [:med_ex] do
        destination = Path.join([tests, "providers", to_string(app)])
        File.mkdir_p!(Path.dirname(destination))
        File.cp_r!(Path.join([@repo, "extensions", to_string(app), "test"]), destination)
        "Code.require_file(\"providers/#{app}/test_helper.exs\", __DIR__)\n"
      end

    File.write!(Path.join(tests, "test_helper.exs"), ["ExUnit.start()\n" | helpers])
  end

  defp compare_modules!(ctx, profile, inventory) do
    reference = Path.join(ctx.stage, "modules-#{profile}.json")
    actual = read_json!(inventory)

    if File.regular?(reference) do
      unless read_json!(reference) == actual, do: raise("Module inventory changed for #{profile}")
    else
      File.cp!(inventory, reference)
    end

    if ctx.evidence do
      File.cp!(inventory, Path.join(ctx.evidence, "modules-#{profile}.json"))
    end
  end

  defp assert_lock!(ctx, work, apps, specs, archives) do
    lock = read_lock(Path.join(work, "mix.lock"))

    for app <- apps do
      case {Map.fetch!(specs, app), Map.get(lock, app)} do
        {[], {:hex, ^app, version, _, _, _, "hexpm", checksum}} ->
          unless version == ctx.versions[app] and checksum == archives[app].sha256 do
            raise "Registry resolution differs from the candidate tarball for #{app}"
          end

        {options, {:git, origin, rev, locked_options}} ->
          unless options[:git] == origin and options[:ref] == rev and
                   options[:subdir] == locked_options[:subdir] do
            raise "Git resolution differs from the selected revision or subdir for #{app}"
          end

        {[path: _], nil} ->
          :ok

        {options, nil} when is_list(options) ->
          unless Keyword.has_key?(options, :path), do: raise("Git/Hex lock missing for #{app}")

        _ ->
          raise "Unexpected Mix source in lock for #{app} at #{work}"
      end
    end
  end

  defp projected_archives!(ctx, invoker) do
    revision = clean_source_revision!(ctx, "projected-registry")
    invoker = invoker || Path.join(@repo, "tools/maintainer")
    manifest = Path.join(@repo, "build_support/weld.exs")

    refresh_projection!(ctx, invoker, manifest, :med_ex)
    verify_source_revision!(ctx, revision, "projected-registry-refresh")

    projects = projected!(ctx, "full", revision)
    archives = build_family!(ctx, projects, "projected")
    verify_source_revision!(ctx, revision, "projected-registry-finish")
    archives
  end

  @doc false
  def refresh_projection!(ctx, invoker, manifest, app) do
    mix!(
      ctx,
      "projected-refresh-#{app}",
      invoker,
      ["weld.project", manifest, "--artifact", to_string(app)],
      official_env(ctx),
      "dev"
    )
  end

  defp prepared_archives!(ctx) do
    revision = clean_source_revision!(ctx, "registry")
    {project, integrity} = projection_path!(:med_ex, "prepared", revision)
    name = "med_ex-#{ctx.versions[:med_ex]}.tar"
    source = Path.join(Path.dirname(project), name)
    path = Path.join([ctx.stage, "packages", "prepared", "med_ex", name])

    unless digest(File.read!(source)) == integrity["archive_sha256"],
      do: raise("Invalid prepared base archive")

    File.mkdir_p!(Path.dirname(path))
    File.cp!(source, path)
    providers = build_family!(ctx, direct(), "direct-providers", [:med_ex_opus, :med_ex_rtc])
    Map.put(providers, :med_ex, inspect_archive!(ctx, :med_ex, path))
  end

  defp build_family!(ctx, specs, label, apps \\ @apps) do
    specs =
      if :med_ex in apps and specs[:med_ex][:path] == @repo,
        do: projected!(ctx, "full"),
        else: specs

    Map.new(apps, fn app ->
      dir = Path.join([ctx.stage, "packages", label, to_string(app)])
      File.mkdir_p!(dir)
      archive = Path.join(dir, "#{app}-#{ctx.versions[app]}.tar")
      source = specs[app][:path]

      mix!(
        ctx,
        "#{label}-#{app}-hex-build",
        source,
        ["hex.build", "--output", archive],
        official_env(ctx),
        "dev"
      )

      {app, inspect_archive!(ctx, app, archive)}
    end)
  end

  defp inspect_archive!(ctx, app, archive) do
    {:ok, entries} = :erl_tar.extract(String.to_charlist(archive), [:memory])
    entries = Map.new(entries, fn {name, bytes} -> {to_string(name), bytes} end)
    metadata = Path.join(Path.dirname(archive), "metadata.config")
    File.write!(metadata, Map.fetch!(entries, "metadata.config"), [:exclusive])
    {:ok, fields} = :file.consult(String.to_charlist(metadata))
    fields = Map.new(fields, fn {name, value} -> {to_string(name), value} end)

    requirements = normalize_requirements!(Map.fetch!(fields, "requirements"))

    name = to_string(app)

    for key <- ~w(name app),
        do: unless(fields[key] == name, do: raise("Wrong Hex #{key} in #{archive}"))

    unless fields["version"] == ctx.versions[app], do: raise("Wrong Hex version in #{archive}")
    verify_requirements!(app, ctx.version, requirements)

    gzip = Map.fetch!(entries, "contents.tar.gz")
    {:ok, package_files} = :erl_tar.extract({:binary, gzip}, [:compressed, :memory])
    files = Enum.map(package_files, fn {relative, bytes} -> {to_string(relative), bytes} end)
    verify_package_files!(app, files)

    result = %{
      archive: archive,
      sha256: digest(File.read!(archive)),
      signature: %{identity: Map.take(fields, ~w(name app version)), requirements: requirements},
      files: files
    }

    if ctx.evidence do
      label = Path.basename(Path.dirname(Path.dirname(archive)))

      File.write!(
        Path.join(ctx.evidence, "#{label}-#{app}-hex.json"),
        JSON.encode!(%{
          sha256: result.sha256,
          metadata: result.signature,
          files: Enum.map(files, &elem(&1, 0))
        })
      )
    end

    result
  end

  @doc false
  def normalize_requirements!(requirements) do
    entries =
      Enum.map(requirements, fn
        {name, properties} ->
          name = to_string(name)
          props = normalize_requirement_properties(properties)

          if Map.get(props, "name", name) != name do
            raise "Hex requirement name mismatch: #{name}"
          end

          {name, Map.put(props, "name", name)}

        properties when is_list(properties) or is_map(properties) ->
          props = normalize_requirement_properties(properties)
          name = Map.fetch!(props, "name")
          {name, props}
      end)

    normalized = Map.new(entries)

    unless map_size(normalized) == length(entries) do
      raise "Duplicate Hex requirement names"
    end

    normalized
  end

  defp normalize_requirement_properties(properties) do
    Map.new(properties, fn {key, value} -> {to_string(key), value} end)
  end

  defp verify_requirements!(:med_ex, _version, requirements) when map_size(requirements) == 0,
    do: :ok

  defp verify_requirements!(:med_ex, _version, requirements),
    do:
      raise("Base package unexpectedly has Hex requirements: #{inspect(Map.keys(requirements))}")

  defp verify_requirements!(app, _version, requirements) do
    forbidden = ~w(med_ex med_ex_opus med_ex_rtc med_core med_capture weld mix_workspace_ops)

    unless Enum.all?(requirements, fn {name, opts} ->
             name not in forbidden and is_binary(opts["requirement"]) and
               opts["repository"] in [nil, "hexpm"] and
               Enum.all?(~w(path git github ref subdir), &(not Map.has_key?(opts, &1)))
           end),
           do: raise("Unexpected or non-Hex dependency in independent #{app} metadata")
  end

  @doc false
  def verify_package_files!(app, files) do
    names = Enum.map(files, &elem(&1, 0))

    for path <- names do
      segments = path_segments!(path)

      if Enum.any?(
           segments,
           &(&1 in ~w(.git .weld deps _build test tools extensions .mix_sources.json))
         ) or
           (Path.basename(path) == "mix.exs" and path != "mix.exs") do
        raise "Unexpected source or working file in #{app} Hex contents: #{path}"
      end
    end

    unless "mix.exs" in names, do: raise("Hex contents for #{app} lack mix.exs")

    case app do
      :med_ex ->
        if Enum.any?(names, &Regex.match?(~r{(^|/)lib/med_ex/(opus|rtc)/}, &1)),
          do: raise("Native extension source in base tarball")

      :med_ex_opus ->
        for input <- ~w(lib/med_ex/opus/provider.ex Makefile
                        c_src/opus_encoder.c c_src/build_native.sh c_src/vendor/SHA256SUMS),
            input not in names,
            do: raise("Opus build input missing: #{input}")

      :med_ex_rtc ->
        unless "lib/med_ex/rtc/provider.ex" in names, do: raise("RTC provider source missing")
    end

    :ok
  end

  defp archive_paths(ctx, archives) do
    Map.new(archives, fn {app, archive} ->
      path = Path.join([ctx.stage, "unpacked", to_string(app)])

      for {relative, bytes} <- archive.files do
        _ = path_segments!(relative)
        target = Path.join(path, relative)
        File.mkdir_p!(Path.dirname(target))
        File.write!(target, bytes, [:exclusive])
      end

      {app, [path: path]}
    end)
  end

  defp with_registry(ctx, archives, action, extra_lock \\ nil) do
    bootstrap = official_bootstrap!(ctx)
    public = Path.join(ctx.stage, "registry")
    tarballs = Path.join(public, "tarballs")
    File.mkdir_p!(tarballs)
    fetch_third_party!(ctx, bootstrap, tarballs, extra_lock, archives)

    for {_app, archive} <- archives do
      File.cp!(archive.archive, Path.join(tarballs, Path.basename(archive.archive)))
    end

    key = registry_key!(ctx)

    mix!(
      ctx,
      "registry-build",
      ctx.stage,
      ["hex.registry", "build", public, "--name=hexpm", "--private-key=#{key}"],
      official_env(ctx),
      "dev"
    )

    {:ok, _} = Application.ensure_all_started(:inets)

    {:ok, server} =
      :inets.start(:httpd,
        port: 0,
        bind_address: {127, 0, 0, 1},
        server_name: ~c"localhost",
        server_root: String.to_charlist(ctx.stage),
        document_root: String.to_charlist(public)
      )

    try do
      {:httpd, ^server, info} = List.keyfind(:inets.services_info(), server, 1)
      port = Keyword.fetch!(info, :port)
      url = "http://127.0.0.1:#{port}"
      env = registry_env(ctx)

      mix!(
        ctx,
        "registry-configure",
        ctx.stage,
        [
          "hex.repo",
          "set",
          "hexpm",
          "--url",
          url,
          "--public-key",
          Path.join(public, "public_key")
        ],
        env,
        "dev"
      )

      configured =
        mix!(ctx, "registry-url", ctx.stage, ["hex.repo", "show", "hexpm", "--url"], env, "dev")

      unless String.trim(configured) == url,
        do: raise("Hex is not using the temporary loopback repo")

      action.(env, archives)
    after
      :inets.stop(:httpd, server)
    end
  end

  defp official_bootstrap!(ctx) do
    bootstrap = Path.join(ctx.stage, "official-resolution")

    unless File.regular?(Path.join(bootstrap, "mix.lock")) do
      create_consumer!(ctx, bootstrap, @apps, direct(), true)
      mix!(ctx, "official-resolve", bootstrap, ["deps.get"], official_env(ctx))
    end

    bootstrap
  end

  defp registry_key!(ctx) do
    retained? = ctx.optimized
    key = Path.join(if(retained?, do: ctx.evidence, else: ctx.stage), "registry-key.pem")

    case File.lstat(key) do
      {:ok, %{type: :regular, mode: mode}} when retained? and Bitwise.band(mode, 0o077) == 0 ->
        key

      {:error, :enoent} ->
        command!(ctx, "registry-key", "openssl", ["genrsa", "-out", key, "2048"], ctx.stage)
        File.chmod!(key, 0o600)
        key

      _ ->
        raise "Unsafe qualification registry key"
    end
  end

  defp fetch_third_party!(ctx, bootstrap, tarballs, extra_lock, archives) do
    locks = [
      Path.join(bootstrap, "mix.lock")
      | Enum.map(direct(), fn {_app, opts} -> Path.join(opts[:path], "mix.lock") end)
    ]

    packages =
      for path <- locks,
          {app, {:hex, package, version, _, _, _, repo, checksum}} <- read_lock(path),
          app not in @apps,
          do: {to_string(package), version, repo, checksum}

    candidates = MapSet.new(archives, fn {app, _} -> {to_string(app), ctx.versions[app]} end)

    additional =
      for path <- List.wrap(extra_lock),
          {_, {:hex, package, version, _, _, _, repo, checksum}} <- read_lock(path),
          to_string(package) not in Enum.map(@apps, &to_string/1) and
            not MapSet.member?(candidates, {to_string(package), version}),
          do: {to_string(package), version, repo, checksum}

    for {package, version, repo, checksum} <- Enum.uniq(packages ++ additional) do
      unless repo == "hexpm" and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, package) and
               match?({:ok, _}, Version.parse(version)) and
               Regex.match?(~r/\A[0-9a-f]{64}\z/, checksum) do
        raise "Unsupported or unchecked official dependency #{package} #{version}"
      end

      target = Path.join(tarballs, "#{package}-#{version}.tar")

      unless File.exists?(target) do
        cached =
          Path.join([
            ctx.hex_home,
            "packages",
            repo,
            "#{package}-#{version}.tar"
          ])

        if File.regular?(cached) do
          File.cp!(cached, target)
          IO.puts("Reusing official tarball: #{package}-#{version}")
        else
          mix!(
            ctx,
            "fetch-#{package}-#{version}",
            tarballs,
            ["hex.package", "fetch", package, version, "--repo", repo],
            official_env(ctx),
            "dev"
          )
        end
      end

      unless digest(File.read!(target)) == checksum, do: raise("Checksum mismatch for #{target}")
    end
  end

  defp standalone_extensions!(ctx, full, env, _archives) do
    for app <- @apps -- [:med_ex] do
      work = detach!(ctx, full[app][:path], "standalone-#{app}")
      mix!(ctx, "#{app}-standalone-resolve", work, ["deps.get"], env)

      unless not Map.has_key?(read_lock(Path.join(work, "mix.lock")), :med_ex),
        do: raise("Base dependency leaked into #{app}")

      mix!(ctx, "#{app}-standalone-test", work, ["test"], env)
      mix!(ctx, "#{app}-standalone-doc-deps", work, ["deps.get"], env, "dev")
      mix!(ctx, "#{app}-standalone-docs", work, ["docs", "--warnings-as-errors"], env, "dev")
    end
  end

  defp verify_combined_release!(ctx, env, archives) do
    work = Path.join([ctx.stage, "consumers", "registry-both"])
    release = Path.join(work, "release")
    mix!(ctx, "combined-release-resolve", work, ["deps.get"], env, "prod")
    assert_lock!(ctx, work, @apps, registry_specs(), archives)
    mix!(ctx, "combined-release", work, ["release", "--path", release], env, "prod")
    installed = release |> Path.join("lib") |> File.ls!()

    for app <- @apps do
      unless Enum.filter(installed, &String.starts_with?(&1, "#{app}-")) == [
               "#{app}-#{ctx.versions[app]}"
             ] do
        raise "Unexpected #{app} release application inventory"
      end
    end

    for app <- ~w(med_core med_capture med_rtc med_ex_maintainer weld mix_workspace_ops) do
      if Enum.any?(installed, &String.starts_with?(&1, "#{app}-")) do
        raise "Unexpected #{app} in combined release"
      end
    end
  end

  defp official_env(ctx) do
    preserve_proxies = ~w(HTTP_PROXY HTTPS_PROXY http_proxy https_proxy)
    [{"HEX_HOME", ctx.hex_home} | Enum.map(@hex_overrides -- preserve_proxies, &{&1, nil})]
  end

  defp registry_env(ctx) do
    [
      {"HEX_HOME", Path.join(ctx.stage, "registry-hex")},
      {"NO_PROXY", "127.0.0.1,localhost"},
      {"no_proxy", "127.0.0.1,localhost"} | Enum.map(@hex_overrides, &{&1, nil})
    ]
  end

  defp mix!(ctx, label, cwd, args, env, mix_env \\ "test") do
    clean = Enum.map(@mix_paths, &{&1, nil})
    command!(ctx, label, "mix", args, cwd, [{"MIX_ENV", mix_env} | clean ++ env])
  end

  defp git!(ctx, label, args, cwd), do: command!(ctx, label, "git", args, cwd)

  defp command!(ctx, label, program, args, cwd, env \\ [], expected \\ :success) do
    label = Map.get(ctx, :label, "") <> label
    started = System.monotonic_time(:millisecond)
    {output, status} = System.cmd(program, args, cd: cwd, env: env, stderr_to_stdout: true)
    elapsed = System.monotonic_time(:millisecond) - started
    summary = "#{label} (#{elapsed} ms, exit #{status})"
    IO.puts(summary)

    if ctx.evidence,
      do: File.write!(Path.join(ctx.evidence, "#{label}.log"), [summary, "\n", output])

    if status == 0 != (expected == :success),
      do: raise("#{summary} in #{cwd}\n\n#{failure_output(ctx, label, output)}")

    if List.first(args) == "test" do
      output
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, ["Result:", "Finished in "]))
      |> Enum.each(&IO.puts/1)
    end

    output
  end

  defp failure_output(%{evidence: nil}, _label, output), do: output

  defp failure_output(ctx, label, output) do
    tail =
      output
      |> String.split("\n")
      |> Enum.take(-40)
      |> Enum.join("\n")

    "Full log: #{Path.join(ctx.evidence, label <> ".log")}\n#{tail}"
  end

  defp read_lock(path) do
    case File.read(path) do
      {:error, :enoent} ->
        %{}

      {:ok, bytes} ->
        ast = Code.string_to_quoted!(bytes, file: path)
        unless Macro.quoted_literal?(ast), do: raise("Expected literal Mix lock in #{path}")
        {lock, []} = Code.eval_quoted(ast, [], file: path)
        lock
    end
  end

  defp regular_file!(root, relative) do
    path =
      Enum.reduce(path_segments!(relative), root, fn segment, parent ->
        location = Path.join(parent, segment)

        unless File.lstat!(location).type in [:directory, :regular],
          do: raise("Unsafe detached path #{location}")

        location
      end)

    unless File.regular?(path), do: raise("Expected regular file #{path}")
    path
  end

  defp path_segments!(path) do
    segments = Path.split(path)

    unless Path.type(path) == :relative and segments != [] and
             Enum.all?(segments, &(&1 not in [".", "..", ""])),
           do: raise("Unsafe inventory path #{inspect(path)}")

    segments
  end

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()
  defp digest(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp temporary_directory! do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    path = Path.join(System.tmp_dir!(), "med-ex-consumer-#{suffix}")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    path
  end

  defp evidence_directory!(nil), do: nil

  defp evidence_directory!(path) do
    directory = Path.expand(path)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    directory
  end
end
