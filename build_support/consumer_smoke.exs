defmodule ExternalDeviceDriverTest do
  use ExUnit.Case

  setup context do
    if dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  alias MedEx.{StreamWriter, SampleFrame, StreamSpec}

  test "ordinary Mix owns exactly the selected applications and browser assets" do
    profile = System.fetch_env!("SDK_PROFILE")
    transport = System.fetch_env!("SDK_TRANSPORT")
    source = System.fetch_env!("SDK_SOURCE_ROOT")
    version = source |> Path.join("VERSION") |> File.read!() |> String.trim()
    dependency_projects = Mix.Project.deps_paths()
    deps = Map.keys(dependency_projects)
    opus? = profile in ["opus", "both"]
    rtc? = profile in ["rtc", "both"]

    assert :med_ex_opus in deps == opus?
    assert :membrane_core in deps == opus?
    assert :membrane_opus_plugin in deps == opus?
    assert :med_ex_rtc in deps == rtc?
    assert :ex_webrtc in deps == rtc?

    forbidden = [
      :med_core,
      :med_capture,
      :med_rtc,
      :med_ex_maintainer,
      :weld,
      :mix_workspace_ops
    ]

    for app <- forbidden, do: refute(app in deps)

    apps =
      [:med_ex] ++
        if(opus?, do: [:med_ex_opus], else: []) ++ if(rtc?, do: [:med_ex_rtc], else: [])

    started = MapSet.new(Application.started_applications(), &elem(&1, 0))

    modules =
      for app <- apps, into: %{} do
        assert MapSet.member?(started, app)
        assert to_string(Application.spec(app, :vsn)) == version
        owned = Application.spec(app, :modules)
        assert is_list(owned) and owned != []

        for module <- owned do
          assert Application.get_application(module) == app

          if transport in ["full", "prepared", "tracked", "archive", "registry"] do
            project = dependency_projects |> Map.fetch!(app) |> Path.expand()
            compiled_from = module.module_info(:compile) |> Keyword.fetch!(:source) |> to_string()
            assert String.starts_with?(Path.expand(compiled_from), project <> "/")
          end
        end

        {app, Enum.sort(owned)}
      end

    implemented = modules |> Map.values() |> List.flatten()
    assert implemented == Enum.uniq(implemented)
    assert StreamSpec in modules.med_ex
    if opus?, do: assert(MedEx.Opus.Provider in modules.med_ex_opus)
    if rtc?, do: assert(MedEx.RTC.Provider in modules.med_ex_rtc)

    for asset <- ~w(pcm_capture.js pcm_worklet.js session_hook.js) do
      assert File.read!(MedEx.Web.asset_path(asset)) ==
               File.read!(Path.join([source, "priv", "static", "med_web", asset]))
    end

    if evidence = System.get_env("SDK_EFFECTIVE_INPUTS") do
      File.write!(evidence, JSON.encode!(effective_inputs(modules, dependency_projects, source)))
    end

    File.write!(
      System.fetch_env!("SDK_MODULE_INVENTORY"),
      JSON.encode!(Map.new(modules, fn {app, owned} -> {app, Enum.map(owned, &to_string/1)} end))
    )
  end

  defp effective_inputs(modules, paths, source) do
    lock = Mix.Dep.Lock.read()

    for {app, {:git, _url, revision, _opts}} <- Map.take(lock, Map.keys(modules)) do
      assert {^revision, 0} =
               subprocess_head(Map.fetch!(paths, app))
    end

    sdk =
      Map.new(modules, fn {app, owned} ->
        executable =
          Map.new(owned, fn module ->
            path = :code.which(module)
            {:ok, {^module, md5}} = :beam_lib.md5(path)
            metadata = module.module_info(:compile)

            {inspect(module),
             [
               Base.encode16(md5, case: :lower),
               hash(File.read!(metadata[:source])),
               hash(:erlang.term_to_binary(metadata[:options], [:deterministic]))
             ]}
          end)

        specification =
          app
          |> Application.spec()
          |> Keyword.drop([:description, :id])
          |> Enum.sort()

        {app, %{beams: executable, application: hash(:erlang.term_to_binary(specification))}}
      end)

    assets =
      Map.new(~w(pcm_capture.js pcm_worklet.js session_hook.js), fn asset ->
        {asset, hash(File.read!(MedEx.Web.asset_path(asset)))}
      end)

    test_inputs =
      for app <- Map.keys(modules) -- [:med_ex],
          file <- Path.wildcard(Path.join([source, "extensions", to_string(app), "test", "**/*"])),
          File.regular?(file),
          do: {Path.relative_to(file, source), hash(File.read!(file))}

    %{
      sdk: sdk,
      assets: assets,
      provider_tests: Enum.sort(test_inputs) |> Map.new(),
      dependency_lock:
        hash(:erlang.term_to_binary(Map.drop(lock, Map.keys(modules)), [:deterministic])),
      compiler_env: Mix.env(),
      compiler_target: Mix.target()
    }
  end

  defp subprocess_head(path) do
    {output, status} = System.cmd("git", ["rev-parse", "HEAD"], cd: path)
    {String.trim(output), status}
  end

  defp hash(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  @tag :tmp_dir
  test "public root records both raw streams with the stream-v1 contract", %{tmp_dir: dir} do
    assert MedEx.Contract.api_revision() == 1

    for {name, rate} <- [{"ecg", 250}, {"diagnostic_audio", 48_000}] do
      spec = %StreamSpec{
        acquisition_id: "a",
        source_ref: "driver",
        boot_id: "boot",
        stream_id: name,
        source_epoch: 0,
        descriptor_ref: String.duplicate("0", 64),
        modality: "medex:" <> name,
        channels: [%{id: "one", label: "1", unit: :unknown, calibration: :unknown}],
        encoding: :s16le,
        sample_rate: {rate, 1},
        capabilities: %{
          encodings: [:s16le],
          max_frame_samples: 2,
          max_payload_bytes: 4,
          replay: :none,
          commands: []
        }
      }

      spec = %{spec | descriptor_ref: MedEx.Serialization.descriptor_ref(spec)}

      frame = %SampleFrame{
        stream_id: name,
        source_epoch: 0,
        descriptor_ref: spec.descriptor_ref,
        sequence: 0,
        first_sample: 0,
        sample_count: 2,
        config_epoch: :unknown,
        payload: <<7, 0, 9, 0>>
      }

      path = Path.join(dir, name)

      assert {:ok, w} =
               StreamWriter.start_link(
                 owner: self(),
                 stream: spec,
                 artifact_dir: path,
                 fence: "f"
               )

      assert {:ok, _} = StreamWriter.push(w, frame)
      assert {:ok, %{segments: [chunk]}} = StreamWriter.finish(w)
      assert MedEx.Storage.File.read_segment(path, chunk) == {:ok, frame.payload}
    end
  end
end
