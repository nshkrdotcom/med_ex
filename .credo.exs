%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["core/*/{lib,test}/**/*.{ex,exs}", "test/**/*.{ex,exs}"]
      }
    }
  ]
}
