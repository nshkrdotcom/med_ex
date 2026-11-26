# This declaration is shared by the direct Mix project and the Weld manifest.
version_file = "VERSION"
version = File.read!(Path.join(__DIR__, "../" <> version_file)) |> String.trim()
source_url = "https://github.com/nshkrdotcom/med_ex"

components = ~w(core/med_core core/med_capture)

groups = [
  {"Overview",
   [
     {"README.md", "Overview"},
     {"guides/architecture_and_roadmap.md", "Architecture and Composition"}
   ]},
  {"Integration Guides",
   [
     {"guides/stream_recording.md", "Streams, Storage, Clock, and Control"},
     {"guides/durability_and_guarantees.md", "Durability and Ordering Guarantees"},
     {"guides/stability_and_compatibility.md", "Public Surface and 0.x Compatibility"},
     {"guides/host_integration.md", "Host Integration and Browser Compatibility"},
     {"guides/source_development.md", "Consumption, Extensions, and Verification"}
   ]},
  {"Horizon", [{"guides/product_horizon.md", "Medical-Device Product Horizon"}]},
  {"Release",
   [
     {"CHANGELOG.md", "Changelog"},
     {"guides/history/med_rtc_changelog.md", "Historical MedRTC Changelog"},
     {"LICENSE", "License"}
   ]}
]

extras = Enum.flat_map(groups, &elem(&1, 1))

%{
  components: components,
  version_file: version_file,
  documents: Enum.map(extras, &elem(&1, 0)),
  assets: ~w(assets priv),
  extras: extras,
  package: [
    name: "med_ex",
    otp_app: :med_ex,
    version: version,
    elixir: "~> 1.20",
    description: "Source-preserving waveform and measurement acquisition",
    licenses: ["MIT"],
    links: %{"Source" => source_url},
    development_dependencies: [{:ex_doc, "~> 0.40.5", only: :dev, runtime: false}],
    docs: [
      main: "readme",
      logo: "assets/med_ex.svg",
      assets: %{"assets" => "assets"},
      source_url: source_url,
      extra_titles: Map.new(extras),
      groups_for_extras:
        Enum.map(groups, fn {title, entries} -> {title, Enum.map(entries, &elem(&1, 0))} end),
      mermaid: true
    ]
  ]
}
