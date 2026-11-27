#!/usr/bin/env bash
set -euo pipefail
sdk=${1:?Provide the MedEx checkout}
fabric=$(pwd -P)
sha=$(git -C "$sdk" rev-parse HEAD)
apps=(med_ex med_ex_opus med_ex_rtc)
export MF_SOURCE_QC_CACHE=${2:?Provide a private source-lane cache directory}
mkdir -p "$MF_SOURCE_QC_CACHE"
registry_locks=()
for lock in "$fabric"/apps/*/mix.lock "$fabric"/core/*/mix.lock; do
  registry_locks+=(--registry-lock "$lock")
done
for transport in direct live full prepared git registry; do
  entries='{}'
  for app in "${apps[@]}"; do
    project_source=$sdk
    [[ "$app" == med_ex ]] || project_source="$sdk/extensions/$app"
    case "$transport" in
      direct) entry=$(jq -cn --arg path "$project_source" '{path:$path}') ;;
      live) if [[ "$app" == med_ex ]]; then project_source="$sdk/.weld/v2/live/med_ex"; fi
        entry=$(jq -cn --arg path "$project_source" '{path:$path}') ;;
      full) if [[ "$app" == med_ex ]]; then project_source="$sdk/.weld/v2/full/med_ex/project"; fi
        entry=$(jq -cn --arg path "$project_source" '{path:$path}') ;;
      prepared)
        if [[ "$app" == med_ex ]]; then
          bundle=$(cd "$sdk/tools/maintainer" && mix weld path --root "$sdk" --artifact med_ex --kind bundle)
          project_source="$bundle/project"
        fi
        entry=$(jq -cn --arg path "$project_source" '{path:$path}')
        ;;
      git)
        subdir=''
        [[ "$app" == med_ex ]] || subdir="extensions/$app"
        entry=$(jq -cn --arg ref "$sha" --arg subdir "$subdir" '
          {github:"nshkrdotcom/med_ex",ref:$ref} + (if $subdir=="" then {} else {subdir:$subdir} end)')
        ;;
      registry) entry=$(jq -cn --arg app "$app" '{hex:$app,repo:"hexpm"}') ;;
    esac
    entries=$(jq -c --arg app "$app" --argjson entry "$entry" '.[$app]=$entry' <<< "$entries")
  done
  printf 'Fabric source lane %s\n' "$transport"
  if [[ "$transport" == registry ]]; then
    MED_EX_SOURCE="$entries" "$sdk/build_support/check_consumers.sh" --registry --prepared-packages "${registry_locks[@]}" -- "$fabric/ops/qc_fabric_sources.sh"
  else
    MED_EX_SOURCE="$entries" "$fabric/ops/qc_fabric_sources.sh"
  fi
done
