#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
udid=${1:-$(xcrun simctl list devices available -j | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((x["udid"] for xs in d["devices"].values() for x in xs if x.get("state")=="Booted"), ""))')}
test -n "$udid" || { echo "no booted simulator" >&2; exit 2; }
cache=$(mktemp -d)
xcodebuild build-for-testing -project "$root/CosmoKitAgentDriver.xcodeproj" -scheme AgentDriver -destination "id=$udid" -derivedDataPath "$cache"
xctestrun=$(find "$cache/Build/Products" -name '*.xctestrun' -print -quit)
test -n "$xctestrun"
xcodebuild test-without-building -xctestrun "$xctestrun" -destination "id=$udid" TEST_RUNNER_COSMOKIT_DRIVER_PORT=8877 >/tmp/cosmokit-agent-driver.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do curl -fsS http://127.0.0.1:8877/status && break; sleep 1; done
curl -fsS -X POST http://127.0.0.1:8877/app -d '{"bundle_id":"com.apple.Preferences","action":"launch"}'
tree=$(curl -fsS http://127.0.0.1:8877/tree)
printf '%s\n' "$tree" | tee "$root/../Tests/CosmoKitCLITests/Fixtures/tree-settings.json"
curl -fsS -X POST http://127.0.0.1:8877/quit
echo "driver smoke passed"
