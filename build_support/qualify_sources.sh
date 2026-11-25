#!/usr/bin/env bash
set -euo pipefail
sdk=${1:?Provide the MedEx checkout}
fabric=$(pwd -P)
sha=$(git -C "$sdk" rev-parse HEAD)
apps=(med_ex med_ex_opus med_ex_rtc)
export MF_SOURCE_QC_CACHE=${2:?Provide a private source-lane cache directory}
mkdir -p "$MF_SOURCE_QC_CACHE"
for transport in direct live full prepared git registry; do
  entries='{}'
  for app in "${apps[@]}"; do
    home=$sdk
    [[ "$app" == med_ex ]] || home="$sdk/extensions/$app"
    case "$transport" in
      direct) entry=$(jq -cn --arg path "$home" '{path:$path}') ;;
      live) entry=$(jq -cn --arg path "$sdk/.weld/live/$app" '{path:$path}') ;;
      full) entry=$(jq -cn --arg path "$sdk/.weld/full/$app/project" '{path:$path}') ;;
      prepared)
        read -r schema identity < "$sdk/.weld/releases/$app/CURRENT"
        [[ "$schema" == weld.release/v1 && "$identity" =~ ^[0-9a-f]{64}$ ]]
        entry=$(jq -cn --arg path "$sdk/.weld/releases/$app/$identity/project" '{path:$path}')
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
    MED_EX_SOURCE="$entries" "$sdk/build_support/check_consumers.sh" --registry --prepared-packages -- "$fabric/ops/qc_fabric_sources.sh"
  else
    MED_EX_SOURCE="$entries" "$fabric/ops/qc_fabric_sources.sh"
  fi
done
