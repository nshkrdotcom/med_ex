{composition, _binding} = Code.eval_file("composition.exs", __DIR__)
base = composition.package
base_docs = Keyword.put(base[:docs], :source_ref, "med_ex-v#{base[:version]}")

package =
  base
  |> Keyword.delete(:docs)
  |> Keyword.put(:dev_deps, Keyword.fetch!(base, :development_dependencies))
  |> Keyword.delete(:development_dependencies)

[
  schema: 2,
  workspace: [root: "..", projects: ["core/*", "tools/*"]],
  classify: [tooling: ["tools/maintainer"]],
  publication: [internal_only: ["tools/maintainer"]],
  artifacts: [
    med_ex: [
      layout: :components,
      roots: composition.components,
      inputs:
        Enum.map(
          [
            composition.version_file,
            "mix.exs",
            "build_support/composition.exs",
            "build_support/docs_hook.html"
          ],
          &[path: &1, type: :file]
        ),
      package: package,
      docs: base_docs,
      files: [docs: composition.documents, assets: composition.assets],
      verify: [
        component_tests: true,
        artifact_tests: ["test/projection"],
        hex_build: true,
        hex_publish_check: false
      ]
    ]
  ]
]
