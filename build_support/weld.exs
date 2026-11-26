{composition, _binding} = Code.eval_file("composition.exs", __DIR__)
base = composition.package
base_docs = Keyword.put(base[:docs], :source_ref, "med_ex-v#{base[:version]}")

extensions = [
  med_ex_opus: "Optional Opus encoding provider for MedEx",
  med_ex_rtc: "Optional WebRTC and RTP provider for MedEx"
]

extension_artifacts =
  for {app, description} <- extensions do
    project = "extensions/#{app}"
    root = Path.join(__DIR__, "../" <> project)
    version = File.read!(Path.join(root, "VERSION")) |> String.trim()

    optional =
      Enum.filter(~w(mix.lock .formatter.exs Makefile c_src), &File.exists?(Path.join(root, &1)))

    c_inputs =
      Enum.filter(
        ~w(Makefile c_src/opus_encoder.c c_src/vendor/SHA256SUMS),
        &File.regular?(Path.join(root, &1))
      )

    {app,
     [
       mode: :source_project,
       roots: [project],
       external_projects: ["."],
       source_project: [
         files: ~w(mix.exs VERSION LICENSE README.md CHANGELOG.md assets lib test) ++ optional,
         structural_inputs: ["VERSION" | c_inputs]
       ],
       package: [
         name: Atom.to_string(app),
         otp_app: app,
         version: version,
         elixir: base[:elixir],
         description: description,
         licenses: base[:licenses],
         links: base[:links]
       ],
       verify: [hex_build: true, hex_publish: false]
     ]}
  end

[
  workspace: [root: "..", project_globs: ["core/*", "extensions/*", "tools/*"]],
  classify: [tooling: ["tools/maintainer"]],
  publication: [
    internal_only: ["tools/maintainer"],
    separate: Enum.map(extensions, fn {app, _} -> "extensions/#{app}" end)
  ],
  artifacts:
    [
      med_ex: [
        mode: :package_projection,
        roots: composition.components,
        structural_inputs: [
          composition.version_file,
          "mix.exs",
          "build_support/composition.exs",
          "build_support/docs_hook.html"
        ],
        package: Keyword.put(base, :docs, base_docs),
        output: [docs: composition.documents, assets: composition.assets],
        verify: [
          component_tests: true,
          artifact_tests: ["test/projection"],
          hex_build: true,
          hex_publish: false
        ]
      ]
    ] ++ extension_artifacts
]
