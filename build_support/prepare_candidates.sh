#!/usr/bin/env bash
# Construct the six unpublished candidates using the existing Weld and signed
# registry runners. Lock synchronization and source freeze are separate steps.
set -euo pipefail
umask 077
sdk=$(cd "$(dirname "$0")/.." && pwd -P)
fabric=$(cd "$sdk/../med_fabric" && pwd -P)
matrix="$sdk/build_support/release_matrix.json"
script="$sdk/build_support/prepare_candidates.sh"
mode=${1:-}
[[ $# == 2 || ( $# == 3 && $mode == _build ) ]] || { echo 'Usage: prepare_candidates.sh sync|build NEW_OR_EXISTING_EVIDENCE' >&2; exit 2; }
out=$(realpath -m -- "$2")
attempt=${3:-}
case "$out/" in "$sdk/"*|"$fabric/"*) echo 'Keep evidence outside both checkouts' >&2; exit 2;; esac
cmp -- "$matrix" "$fabric/build_support/release_matrix.json"
for repo in "$sdk" "$fabric"; do
  [[ ! -e "$repo/.mix_sources.json" && ! -L "$repo/.mix_sources.json" ]]
done
unset MIX_ENV MIX_EXS MIX_TARGET MIX_DEPS_PATH MIX_LOCKFILE MIX_BUILD_PATH MIX_BUILD_ROOT

clean() {
  [[ -z $(git -C "$1" status --porcelain) ]] || {
    printf 'Commit and review source changes in %s first\n' "$1" >&2; return 2;
  }
}
version() { jq -er --arg name "$1" '.packages[] | select(.name == $name) | .version' "$matrix"; }
sha() { sha256sum -- "$1" | cut -d' ' -f1; }
archive() {
  local directory=$out
  if [[ $1 == mf_* ]]; then directory=${attempt:?Missing build attempt}; fi
  printf '%s/archives/%s-%s.tar\n' "$directory" "$1" "$(version "$1")"
}
entry() {
  local name=$1 revision=$2 kind=$3 prepared=${4:-} path
  path=$(archive "$name")
  [[ -f "$path" && ! -L "$path" ]]
  if [[ "$kind" == weld ]]; then
    jq -e --arg rev "$revision" --arg name "$name" --arg digest "$(sha "$path")" \
      '.schema == "weld.bundle/2" and .artifact == $name and .source.commit == $rev and .archive_sha256 == $digest' \
      "$prepared" >/dev/null
  fi
  jq -cn --arg name "$name" --arg archive "$path" --arg digest "$(sha "$path")" \
    --arg revision "$revision" --arg build "$kind" --arg prepared "$prepared" \
    '{($name): ({archive:$archive,sha256:$digest,source_revision:$revision,build:$build} +
      (if $build == "weld" then {prepared_release:$prepared} else {} end))}'
}
upstream=(med_ex med_ex_opus med_ex_rtc)
projects=(core/domain core/store apps/exam apps/handheld apps/preview)
registry_locks=()
for lock in "$fabric"/apps/*/mix.lock "$fabric"/core/*/mix.lock \
    "$fabric/mix.lock" "$fabric/tools/maintainer/mix.lock" "$sdk/tools/maintainer/mix.lock"; do
  registry_locks+=(--registry-lock "$lock")
done

# Use the same literal lock reader as the signed registry; compare real pinned
# third-party entries before/after, and confirm exact family tarball checksums.
lock_entries() {
  elixir -r "$sdk/build_support/check_consumers.exs" -e '
    [path] = System.argv()
    MedEx.ConsumerCheck.locked_registry_packages!([path], [])
    |> Enum.map(&Tuple.to_list/1)
    |> JSON.encode!()
    |> IO.puts()
  ' -- "$1"
}
registry_url() {
  local url
  url=$(cd "$sdk" && mix hex.repo show hexpm --url)
  [[ "$url" =~ ^http://127\.0\.0\.1:[0-9]+$ ]] || {
    echo 'Expected the private candidate registry' >&2; return 2;
  }
  printf '%s\n' "$url"
}
verify_locks() {
  local project=$1 before=$2 after=$3
  jq -en --argjson before "$before" --argjson after "$after" \
    --slurpfile upstream "$out/upstream.json" --slurpfile matrix "$matrix" '
      def family: .[0] as $name | $upstream[0] | has($name);
      ([$before[] | select(family | not)] == [$after[] | select(family | not)]) and
      ([$before[] | select(family) | .[0]] == [$after[] | select(family) | .[0]]) and
      ([$after[] | select(family)] | length > 0) and
      all($after[] | select(family); . as $entry |
        .[2] == "hexpm" and .[3] == $upstream[0][.[0]].sha256 and
        .[1] == ($matrix[0].packages[] | select(.name == $entry[0]) | .version))
    ' >/dev/null || { printf 'Unexpected lock resolution: %s\n' "$project" >&2; return 2; }
}
run_registry() {
  local stage=$1 directory=$out
  shift
  if [[ $stage == build ]]; then directory=$1; fi
  (cd "$sdk"; ./build_support/check_consumers.sh --registry --prepared-packages \
    "${registry_locks[@]}" --evidence "$directory/$stage-registry" -- "$script" "_$stage" "$out" "$@")
}

case "$mode" in
  sync)
    clean "$sdk"; clean "$fabric"
    mkdir -m 0700 -- "$out"
    mkdir -- "$out/archives" "$out/before-locks"
    (cd "$sdk"; ./build_support/qualify_ecosystem.sh full --gate medex-prepare --evidence "$out/source-qc")
    run_registry sync
    sha256sum -c -- "$out/upstream-locks.sha256"
    printf 'Review and commit only the genuine Fabric lock changes before build:\n'
    git -C "$fabric" diff --stat
    ;;
  _sync)
    exec > >(tee "$out/sync.log") 2>&1
    clean "$sdk"; clean "$fabric"
    url=$(registry_url)
    revision=$(git -C "$sdk" rev-parse HEAD)
    fabric_revision=$(git -C "$fabric" rev-parse HEAD)
    bundle=$(cd "$sdk/tools/maintainer"; mix weld path --manifest "$sdk/build_support/weld.exs" --artifact med_ex --kind bundle)
    cp -- "$bundle/bundle.json" "$out/archives/med_ex.bundle.json"
    for name in "${upstream[@]}"; do
      curl -fsS --max-time 30 "$url/tarballs/$name-$(version "$name").tar" -o "$(archive "$name")"
    done
    cmp -- "$bundle/package.tar" "$(archive med_ex)"
    { entry med_ex "$revision" weld "$out/archives/med_ex.bundle.json"
      entry med_ex_opus "$revision" mix
      entry med_ex_rtc "$revision" mix; } | jq -s 'add' > "$out/upstream.json"
    for project in "${projects[@]}"; do
      printf 'Resolving %s\n' "$project"
      lock="$fabric/$project/mix.lock"
      mkdir -p -- "$out/before-locks/$project"
      cp -- "$lock" "$out/before-locks/$project/mix.lock"
      before=$(lock_entries "$lock")
      mapfile -t names < <(jq -r --argjson before "$before" --slurpfile upstream "$out/upstream.json" \
        -n '$before[] | .[0] as $name | select($upstream[0] | has($name)) | $name')
      ((${#names[@]} > 0))
      (cd "$fabric/$project"; MIX_ENV=dev mix deps.unlock "${names[@]}"; MIX_ENV=dev mix deps.get; MIX_ENV=dev mix deps.get --check-locked)
      after=$(lock_entries "$lock")
      verify_locks "$project" "$before" "$after"
      sha256sum -- "$lock" >> "$out/upstream-locks.sha256"
    done
    clean "$sdk"
    [[ $(git -C "$sdk" rev-parse HEAD) == "$revision" && $(git -C "$fabric" rev-parse HEAD) == "$fabric_revision" ]]
    printf 'Upstream archives retained and five locks resolved.\n'
    ;;
  build)
    clean "$sdk"; clean "$fabric"
    [[ -f "$out/upstream.json" && -f "$out/upstream-locks.sha256" && ! -e "$out/candidate-inputs.json" ]]
    [[ $(wc -l < "$out/upstream-locks.sha256") == 5 ]]
    sha256sum -c -- "$out/upstream-locks.sha256"
    attempt=$(mktemp -d "$out/build.XXXXXXXX")
    ln -sfn -- "$attempt/build.log" "$out/build.log"
    run_registry build "$attempt"
    printf 'Exact six-candidate manifest: %s/candidate-inputs.json\n' "$out"
    ;;
  _build)
    [[ -d "$attempt" && ! -L "$attempt" && "$attempt" == "$out/build."* ]]
    mkdir -- "$attempt/archives"
    exec > >(tee "$attempt/build.log") 2>&1
    clean "$sdk"; clean "$fabric"
    url=$(registry_url)
    sdk_revision=$(git -C "$sdk" rev-parse HEAD)
    revision=$(git -C "$fabric" rev-parse HEAD)
    for name in "${upstream[@]}"; do
      digest=$(jq -er --arg name "$name" --arg rev "$sdk_revision" '.[$name] | select(.source_revision == $rev) | .sha256' "$out/upstream.json")
      [[ $(sha "$(archive "$name")") == "$digest" ]]
      actual=$(curl -fsS --max-time 30 "$url/tarballs/$name-$(version "$name").tar" | sha256sum | cut -d' ' -f1)
      [[ "$actual" == "$digest" ]] || { echo "Upstream archive changed: $name" >&2; exit 2; }
    done
    curl -fsS --max-time 30 "$url/public_key" -o "$attempt/fabric-registry-public-key"
    "$fabric/build_support/prepare_qualification.sh" "$sdk" "$attempt/fabric-prepared" \
      --registry-url "$url" --registry-public-key "$attempt/fabric-registry-public-key"
    bundle=$(cat "$attempt/fabric-prepared/bundle-path")
    cp -- "$bundle/package.tar" "$(archive mf_exam)"
    cp -- "$bundle/bundle.json" "$attempt/archives/mf_exam.bundle.json"
    for role in handheld preview; do
      (cd "$fabric/apps/$role"; MIX_ENV=dev mix deps.get --check-locked; MIX_ENV=dev mix hex.build --output "$(archive "mf_$role")")
    done
    clean "$sdk"; clean "$fabric"
    [[ $(git -C "$sdk" rev-parse HEAD) == "$sdk_revision" && $(git -C "$fabric" rev-parse HEAD) == "$revision" ]]
    { cat "$out/upstream.json"
      entry mf_exam "$revision" weld "$attempt/archives/mf_exam.bundle.json"
      entry mf_handheld "$revision" mix
      entry mf_preview "$revision" mix; } | jq -s '{schema:"medfabric.detached_inputs.v2",registry:"candidate",packages:add}' > "$attempt/candidate-inputs.pending.json"
    elixir "$fabric/ops/detached_artifacts.exs" inputs "$matrix" "$attempt/candidate-inputs.pending.json" "$attempt/verified-inputs.json"
    mv -- "$attempt/candidate-inputs.pending.json" "$out/candidate-inputs.json"
    ;;
  *) echo 'Use sync or build with an explicit private evidence directory' >&2; exit 2;;
esac
