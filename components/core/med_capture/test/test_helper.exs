ExUnit.start()

if Mix.Project.config()[:app] == :med_capture,
  do:
    Application.put_env(
      :med_capture,
      :test_asset_dir,
      Path.expand("../../../priv/static/med_web", __DIR__)
    )
