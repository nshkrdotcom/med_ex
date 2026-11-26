defmodule MedEx.DocsHookTest do
  use ExUnit.Case, async: true

  @hook_file "build_support/docs_hook.html"

  test "the root docs hook and the manifest's hook_file are the same single file" do
    composition = elem(Code.eval_file("build_support/composition.exs"), 0)
    assert composition.package[:docs][:hook_file] == @hook_file

    root_hook = Mix.Project.config()[:docs][:before_closing_body_tag]
    assert root_hook.(:html) == File.read!(@hook_file)
    assert root_hook.(:epub) == ""
    assert File.read!(@hook_file) =~ "exdoc:loaded"
  end
end
