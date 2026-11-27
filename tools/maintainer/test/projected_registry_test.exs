Code.require_file("../../../build_support/check_consumers.exs", __DIR__)

defmodule MedEx.ProjectedRegistryTest do
  use ExUnit.Case, async: false

  test "registry refresh replaces a dirty-source projection after reverting to the same HEAD" do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    root = Path.join(System.tmp_dir!(), "medex-registry-freshness-#{suffix}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.mkdir_p!(Path.join(root, "build_support"))
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, ".gitignore"), ".weld/\n_build/\ndeps/\nmix.lock\n")

    File.write!(Path.join(root, "mix.exs"), """
    defmodule RegistryFreshness.MixProject do
      use Mix.Project
      def project do
        [app: :registry_freshness, version: "0.1.0", deps: [],
         package: [files: ["mix.exs", "lib"]]]
      end
    end
    """)

    manifest = Path.join(root, "build_support/weld.exs")

    File.write!(manifest, """
    [
      schema: 2,
      workspace: [root: "..", projects: ["."]],
      artifacts: [
        registry_freshness: [
          layout: :components,
          roots: ["."],
          package: [name: "registry_freshness", otp_app: :registry_freshness,
                    version: "0.1.0", description: "Registry freshness fixture"],
          verify: [hex_build: false, hex_publish_check: false]
        ]
      ]
    ]
    """)

    source = Path.join(root, "lib/registry_freshness.ex")
    original = "defmodule RegistryFreshness do\n  def value, do: :original\nend\n"
    changed = String.replace(original, ":original", ":modified")
    File.write!(source, original)
    git!(root, ["init", "-q"])
    git!(root, ["add", "."])

    git!(root, [
      "-c",
      "user.name=MedEx Test",
      "-c",
      "user.email=test@example.test",
      "commit",
      "-q",
      "--no-gpg-sign",
      "-m",
      "Original fixture"
    ])

    revision = git!(root, ["rev-parse", "HEAD"]) |> String.trim()
    File.write!(source, changed)
    Weld.Output.setup!(root)
    projection = Weld.Commands.project!(manifest, artifact: "registry_freshness")

    [projected_source] =
      Path.wildcard(Path.join(projection.build_path, "**/lib/registry_freshness.ex"))

    assert File.read!(projected_source) == changed
    File.write!(source, original)
    assert git!(root, ["status", "--porcelain"]) == ""

    # A dirty-source view can still report the same Git revision. Refresh must
    # validate current input facts, not trust that revision alone.
    assert projection.git_revision == revision
    invoker = Mix.Project.project_file() |> Path.dirname() |> Path.expand()
    context = %{evidence: nil, hex_home: Path.join(root, "_build/test-hex")}

    refreshed =
      MedEx.ConsumerCheck.refresh_projection!(context, invoker, manifest, :registry_freshness)

    assert File.read!(projected_source) == original
    assert String.trim(git!(root, ["rev-parse", "HEAD"])) == revision
    assert git!(root, ["status", "--porcelain"]) == ""

    assert :ok =
             MedEx.ConsumerCheck.check_projection_identity!(
               refreshed,
               :registry_freshness,
               "full",
               revision
             )

    assert :ok =
             MedEx.ConsumerCheck.verify_prepared_tree!(
               refreshed["build_path"],
               refreshed["observation"]
             )
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
