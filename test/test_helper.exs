ExUnit.start(exclude: if(System.get_env("MED_EX_ENOSPC_ROOT"), do: [], else: [:enospc]))
Code.require_file("../core/med_capture/test/support/fixture_helper.exs", __DIR__)
