#!/bin/bash
# Upgrade a synthetic vault on UUID-selected simulators. Never installs over
# the production bundle ID. It makes no signing or portal changes.
set -euo pipefail
cd "$(dirname "$0")/../.."
base=${1:?Usage: smoke.sh INTEGRATION_COMMIT SIMULATOR_UUID [SIMULATOR_UUID ...]}
shift
if (( $# == 0 )); then
  echo "Pass at least one simulator UUID." >&2
  exit 2
fi
for uuid in "$@"; do
  xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = [device for group in json.load(sys.stdin)["devices"].values() for device in group]
matches = [device for device in devices if device["udid"].upper() == sys.argv[1].upper()]
if len(matches) != 1 or matches[0]["name"].startswith("iPhone 17"):
    sys.exit("Select an available simulator by UUID. iPhone 17 models are excluded.")
print(matches[0]["name"], matches[0]["udid"])
' "$uuid"
done

scratch=$(mktemp -d "${TMPDIR:-/tmp}/docscanner-vault-smoke.XXXXXXXX")
echo "Build logs: $scratch"
first=$1
tag=$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)
live_id="tn.document-scaner.vaultqa-$tag"
missed_id="tn.document-scaner.vaultmissed-$tag"
paths=(document-scaner.xcodeproj document-scaner document-scanerTests document-scanerUITests document-scaner-Info.plist Config)
mkdir "$scratch/legacy" "$scratch/bridge"
git archive "$base" -- "${paths[@]}" | tar xf - -C "$scratch/legacy"
cp -R "${paths[@]}" "$scratch/bridge/"
rm -f "$scratch/bridge/Config/LocalOverrides.xcconfig"
for tree in legacy bridge; do
  cp scripts/vault-transfer/VaultTransferSmoke.swift "$scratch/$tree/document-scaner/Services/"
  python3 - "$scratch/$tree/document-scaner/document_scanerApp.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
needle = '            ContentView()'
assert s.count(needle) == 1
s = s.replace(needle, '''            Group {
                if VaultTransferSmoke.enabled {
                    ProgressView("Vault simulator check")
                        .task { await VaultTransferSmoke.run() }
                } else {
                    ContentView()
                }
            }''')
p.write_text(s)
PY
done

build() {
  local tree=$1 name=$2 bundle=$3 team=$4 flags=$5
  xcodebuild build -project "$scratch/$tree/document-scaner.xcodeproj" -scheme document-scaner \
    -destination "platform=iOS Simulator,id=$first" -derivedDataPath "$scratch/$name" \
    "DOCSCANNER_APP_BUNDLE_ID=$bundle" "DEVELOPMENT_TEAM=$team" "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$flags" \
    >"$scratch/$name.log" 2>&1
}
build legacy legacy-live "$live_id" 5S4ZT4SRV9 'DEBUG VAULT_SMOKE_LEGACY'
build bridge bridge-live "$live_id" 5S4ZT4SRV9 DEBUG
build legacy legacy-missed "$missed_id" 5S4ZT4SRV9 'DEBUG VAULT_SMOKE_LEGACY'
# A different simulated application identifier loses the old default group.
# This does not test transfer of a registered production App Group.
build bridge bridge-missed "$missed_id" TESTTEAM01 DEBUG

install() {
  xcrun simctl install "$1" "$scratch/$2/Build/Products/Debug-iphonesimulator/DocScanner.app"
}

run_case() {
  local uuid=$1 bundle=$2 mode=$3 container marker count
  container=$(xcrun simctl get_app_container "$uuid" "$bundle" data)
  marker="$container/Documents/vault-smoke-result"
  rm -f "$marker"
  xcrun simctl launch --terminate-running-process "$uuid" "$bundle" "$mode"
  for ((count=0; count<45; count++)); do
    if [[ -f "$marker" ]]; then
      printf '%s %s: ' "$uuid" "$mode"
      cat "$marker"
      echo
      xcrun simctl terminate "$uuid" "$bundle"
      [[ $(cat "$marker") == PASS ]]
      return
    fi
    # The iOS Simulator emits these events for matching Face ID or Touch ID.
    xcrun simctl spawn "$uuid" notifyutil -p com.apple.BiometricKit_Sim.pearl.match
    xcrun simctl spawn "$uuid" notifyutil -p com.apple.BiometricKit_Sim.fingerTouch.match
    sleep 1
  done
  echo "Timed out waiting for $mode on $uuid." >&2
  return 1
}

failed=0
for uuid in "$@"; do
  xcrun simctl bootstatus "$uuid" -b
  xcrun simctl spawn "$uuid" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
  xcrun simctl spawn "$uuid" notifyutil -p com.apple.BiometricKit.enrollmentChanged

  install "$uuid" legacy-live
  run_case "$uuid" "$live_id" seed || failed=1
  if [[ ${VAULT_SMOKE_LEAVE_LEGACY:-0} != 1 ]]; then
    install "$uuid" bridge-live
    run_case "$uuid" "$live_id" bridge || failed=1
    run_case "$uuid" "$live_id" relaunch || failed=1
  fi

  install "$uuid" legacy-missed
  run_case "$uuid" "$missed_id" missed-seed || failed=1
  install "$uuid" bridge-missed
  run_case "$uuid" "$missed_id" missed || failed=1
done
exit "$failed"
