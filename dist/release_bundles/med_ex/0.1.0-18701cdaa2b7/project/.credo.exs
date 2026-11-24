%{
  configs: [
    %{
      name: "default",
      files: %{
        included: [
          "lib/",
          "core/*/lib/",
          "apps/*/lib/"
        ],
        excluded: [
          "_build/",
          "deps/",
          "dist/",
          "doc/"
        ]
      },
      strict: true,
      color: true
    }
  ]
}
