Code.require_file("../../build_support/qualification_scope.exs", __DIR__)

defmodule MedEx.QualificationScopeTest do
  use ExUnit.Case, async: true

  alias MedEx.Build.QualificationScope, as: Scope

  test "uses downstream consumers for private sources and only relevant provider profiles" do
    assert Scope.medex(["core/med_capture/lib/x.ex"]).profiles == [:base, :opus, :rtc, :both]
    assert Scope.medex(["extensions/med_ex_opus/test/x.exs"]).profiles == [:opus, :both]
    assert Scope.medex(["extensions/med_ex_rtc/mix.lock"]).packaging
    assert Scope.medex(["guides/host_integration.md"]).profiles == []
    assert Scope.medex(["guides/host_integration.md"]).docs
    assert Scope.medex(["priv/static/med_web/new.js"]).profiles == [:base, :opus, :rtc, :both]
    assert Scope.medex(["unknown"]).packaging
    assert Scope.medex([]) == %{profiles: [], architecture: false, packaging: false, docs: false}
  end
end
