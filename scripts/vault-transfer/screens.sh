#!/bin/bash
# Exercise the real recovery screens against the smoke script's isolated,
# missed-bridge app. Screenshots are in the returned .xcresult bundles.
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch=${1:?Usage: screens.sh SMOKE_OUTPUT_DIR SIMULATOR_UUID [SIMULATOR_UUID ...]}
shift
if (( $# == 0 )); then
  echo "Pass at least one simulator UUID." >&2
  exit 2
fi
for uuid in "$@"; do
  xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group]
matches = [d for d in devices if d["udid"].upper() == sys.argv[1].upper()]
if len(matches) != 1 or matches[0]["name"].startswith("iPhone 17"):
    sys.exit("Select an available simulator by UUID. iPhone 17 models are excluded.")
' "$uuid"
done

variant=${VAULT_SCREENS_VARIANT:-recovery}
case "$variant" in
  bridge) product=bridge-live; team=5S4ZT4SRV9; tests=VaultTransferReminderScreenChecks ;;
  recovery) product=bridge-missed; team=TESTTEAM01; tests=VaultTransferScreenChecks ;;
  reauthentication) product=bridge-live; team=5S4ZT4SRV9; tests=VaultReauthenticationScreenChecks ;;
  *) echo "VAULT_SCREENS_VARIANT must be bridge, recovery, or reauthentication." >&2; exit 2 ;;
esac
base_app="$scratch/$product/Build/Products/Debug-iphonesimulator/DocScanner.app"
bundle=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$base_app/Info.plist")
[[ $bundle =~ ^tn\.document-scaner\.vault(qa|missed)-[0-9a-f]+$ ]]
tree=$(mktemp -d "$scratch/screens.$variant.XXXXXXXX")
cp -R document-scaner.xcodeproj document-scaner document-scanerTests document-scanerUITests document-scaner-Info.plist Config "$tree/"
rm -f "$tree/Config/LocalOverrides.xcconfig"
cp scripts/vault-transfer/VaultTransferSmoke.swift "$tree/document-scaner/Services/"
cp scripts/vault-transfer/VaultTransferScreenChecks.swift "$tree/document-scanerUITests/DocumentHeroTransitionUITests.swift"
python3 - "$tree/document-scaner/document_scanerApp.swift" "$variant" <<'PYCODE'
import plistlib
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
assert "DocumentLibrary(proAccess: proStore)" in s
# Suppress the unrelated launch paywall in this isolated app. Settings and
# feature-triggered paywalls still use the real Pro store.
s = s.replace(".proPaywallHost(store: proStore)", "")
s = s.replace("DocumentLibrary(proAccess: proStore)",
              "DocumentLibrary(vaultKeyStore: VaultTransferSmoke.keys(), proAccess: proStore)")
p.write_text(s)
if sys.argv[2] != "bridge":
    plist = p.parent.parent / "document-scaner-Info.plist"
    with plist.open("rb") as handle:
        info = plistlib.load(handle)
    info["VaultTransferReminderEnabled"] = False
    with plist.open("wb") as handle:
        plistlib.dump(info, handle)
PYCODE
echo "Screen test outputs: $tree"
failed=0
for uuid in "$@"; do
  matcher_pid=
  if [[ $variant != recovery ]]; then
    # Simulate a matching biometric on the selected test device only.
    (
      while true; do
        xcrun simctl spawn "$uuid" notifyutil -p com.apple.BiometricKit_Sim.pearl.match
        xcrun simctl spawn "$uuid" notifyutil -p com.apple.BiometricKit_Sim.fingerTouch.match
        sleep 1
      done
    ) >/dev/null 2>&1 &
    matcher_pid=$!
    trap 'kill "$matcher_pid" 2>/dev/null || true' EXIT
  fi
  if xcodebuild test -project "$tree/document-scaner.xcodeproj" -scheme document-scaner \
      -destination "platform=iOS Simulator,id=$uuid" -parallel-testing-enabled NO \
      -derivedDataPath "$tree/derived" -resultBundlePath "$tree/$uuid.xcresult" \
      "-only-testing:document-scanerUITests/$tests" \
      "DOCSCANNER_APP_BUNDLE_ID=$bundle" "DEVELOPMENT_TEAM=$team" \
      >"$tree/$uuid.log" 2>&1; then
    echo "$uuid: PASS"
  else
    echo "$uuid: FAIL ($tree/$uuid.log)" >&2
    failed=1
  fi
  if [[ -n $matcher_pid ]]; then
    kill "$matcher_pid" 2>/dev/null || true
    wait "$matcher_pid" 2>/dev/null || true
    trap - EXIT
  fi
done
exit "$failed"
