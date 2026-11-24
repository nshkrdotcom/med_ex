#!/usr/bin/env bash
# Host acceptance gate. Each consumer lives outside the source checkout with a fresh build and lock.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source_root=$(cd "${1:-$repo}" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
export MIX_ENV=test
mkdir -p "$stage/packages"
build_archive() {
  local project=$1 app=$2
  (cd "$project" && mix hex.build --output "$stage/$app.tar")
  mkdir "$stage/packages/$app"
  tar -xOf "$stage/$app.tar" contents.tar.gz | tar -xz -C "$stage/packages/$app"
}
archive_source="$source_root"
if [[ -f "$source_root/weld.provenance.json" ]] && python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["kind"] != "live")' "$source_root/weld.provenance.json"; then
  # Live projects deliberately refuse packaging. Test their direct path and
  # consume the portable archive of the authoritative root in the archive pass.
  archive_source="$repo"
fi
build_archive "$archive_source" med_ex
for app in med_ex_opus med_ex_rtc; do
  project="$stage/project-$app"
  mkdir "$project"
  cp -R "$repo/extensions/$app"/{lib,build_support,test,VERSION,LICENSE,mix.exs} "$project/"
  python3 - "$project/.mix_sources.json" "$source_root" <<'PYTHON'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as out:
    json.dump({"med_ex": {"path": sys.argv[2]}}, out)
PYTHON
  (cd "$project" && mix deps.get && mix compile --warnings-as-errors && mix test)
  build_archive "$project" "$app"
done

for mode in direct archive; do
  for profile in headless opus rtc both; do
    work="$stage/$mode-$profile"
    mkdir -p "$work/test"
    base="$source_root"
    opus="$repo/extensions/med_ex_opus"
    rtc="$repo/extensions/med_ex_rtc"
    if [[ $mode == archive ]]; then
      base="$stage/packages/med_ex"
      opus="$stage/packages/med_ex_opus"
      rtc="$stage/packages/med_ex_rtc"
    fi
    deps="[{:med_ex, path: System.fetch_env!(\"SDK_BASE\"), override: true}"
    [[ $profile != opus && $profile != both ]] || deps+=', {:med_ex_opus, path: System.fetch_env!("SDK_OPUS")}'
    [[ $profile != rtc && $profile != both ]] || deps+=', {:med_ex_rtc, path: System.fetch_env!("SDK_RTC")}'
    deps+=']'
    cat > "$work/mix.exs" <<MIX
defmodule FreshConsumer.MixProject do
  use Mix.Project
  def project, do: [app: :fresh_consumer, version: "0.0.0", elixir: "~> 1.20", deps: $deps]
end
MIX
    cp "$repo/build_support/consumer_smoke.exs" "$work/test/consumer_smoke_test.exs"
    echo 'ExUnit.start()' > "$work/test/test_helper.exs"
    if [[ $profile == opus || $profile == both ]]; then
      cp "$repo"/extensions/med_ex_opus/test/{capture_preview,preview_session,provider}_test.exs "$work/test/"
      echo 'Application.put_env(:med_ex, :preview_provider, MedEx.Opus.Provider)' >> "$work/test/test_helper.exs"
    fi
    if [[ $profile == rtc || $profile == both ]]; then
      cp "$repo"/extensions/med_ex_rtc/test/preview_test.exs "$work/test/"
      echo 'Application.put_env(:med_ex, :rtc_provider, MedEx.RTC.Provider)' >> "$work/test/test_helper.exs"
    fi
    (cd "$work"
      export SDK_BASE="$base" SDK_OPUS="$opus" SDK_RTC="$rtc" SDK_PROFILE="$profile"
      mix deps.get
      mix compile --warnings-as-errors
      mix test
    )
  done
done
