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
      workspace: [root: "..", project_globs: []],
      artifacts: [
        registry_freshness: [
          mode: :package_projection,
          roots: ["."],
          package: [name: "registry_freshness", otp_app: :registry_freshness,
                    version: "0.1.0", description: "Registry freshness fixture"],
          verify: [hex_build: false, hex_publish: false]
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
    projection = Weld.project!(manifest, artifact: :registry_freshness)
    projected_source = Path.join(projection.build_path, "lib/registry_freshness.ex")
    assert File.read!(projected_source) == changed
    File.write!(source, original)
    assert git!(root, ["status", "--porcelain"]) == ""

    # Both the commit and self-reported projection digest remain valid here.
    assert :ok =
             MedEx.ConsumerCheck.verify_full_projection!(
               projection.build_path,
               :registry_freshness,
               revision
             )

    invoker = Mix.Project.project_file() |> Path.dirname() |> Path.expand()
    context = %{evidence: nil, hex_home: Path.join(root, "_build/test-hex")}

    MedEx.ConsumerCheck.refresh_projection!(context, invoker, manifest, :registry_freshness)

    assert File.read!(projected_source) == original
    assert String.trim(git!(root, ["rev-parse", "HEAD"])) == revision
    assert git!(root, ["status", "--porcelain"]) == ""

    assert :ok =
             MedEx.ConsumerCheck.verify_full_projection!(
               projection.build_path,
               :registry_freshness,
               revision
             )
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
