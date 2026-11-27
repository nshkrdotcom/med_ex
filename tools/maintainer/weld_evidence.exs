# Invoked only from the private maintainer Mix project. No Weld runtime dependency
# enters the SDK or its consumers.
[operation, root, artifact] = System.argv()
manifest = Path.join(root, "build_support/weld.exs")

record =
  case operation do
    "prepared" ->
      {id, bundle} =
        Weld.ReleaseStatus.resolve_path!(%{repo_root: root, artifact: artifact})

      metadata = Weld.ReleaseStatus.validate_bundle_integrity!(bundle, id)
      %{inventory: inventory} = Weld.ReleaseStatus.evidence!(bundle)

      %{
        artifact: metadata["artifact"],
        kind: "prepared",
        source_revision: metadata["source"]["commit"],
        build_path: Path.join(bundle, "project"),
        archive_sha256: metadata["archive_sha256"],
        receipt: Weld.ReleaseReceipt.format_trailers(nil, metadata),
        observation: %{
          "entries" => inventory["frozen_project"],
          "empty_dirs" => inventory["empty_dirs"]
        }
      }

    kind when kind in ["full", "live"] ->
      Weld.Output.setup!(root)
      result = Weld.Commands.project!(manifest, artifact: artifact, kind: kind)

      observation =
        if kind == "full" do
          observed = Weld.Hash.observation(result.build_path)

          unless Weld.Core.Identity.digest("project", observed) == result.tree_digest,
            do: raise("Projection changed after Weld materialization")

          observed
        end

      %{
        artifact: artifact,
        kind: kind,
        source_revision: result.git_revision,
        build_path: result.build_path,
        observation: observation
      }
  end

IO.puts("MEDEX_WELD_EVIDENCE " <> JSON.encode!(record))
