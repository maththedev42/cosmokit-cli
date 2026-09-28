#!/usr/bin/env bash
set -euo pipefail

# Reproducible size/timing benchmark for the public UI-tree surfaces.
# The default screen batches are scroll landmarks in CosmoKitTestApp. Pass
# --screens with the same four names, or extend screen_batch when the fixture
# changes; the measured payloads remain independent of the labels.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
CLI_DIR="$REPO_ROOT/cli"
CLI_BIN="$CLI_DIR/.build/release/cosmokit"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cosmokit-benchmark.XXXXXX")
WRITE=0
UDID=""
APP_BUNDLE="apps.mjkweber.CosmoKitTestApp"
SCREENS_CSV="home,list,form,modal"

cleanup() {
  if [[ "${DRIVER_STARTED:-0}" == "1" ]]; then
    "$CLI_BIN" agent stop "$UDID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Usage: bash cli/scripts/benchmark.sh [options]

Options:
  --udid UDID       Booted simulator UDID (default: first booted simulator)
  --app BUNDLE_ID   Test app bundle identifier
                     (default: apps.mjkweber.CosmoKitTestApp)
  --screens LIST     Exactly four comma-separated fixture screens
                     (default: home,list,form,modal)
  --write            Write the report to cli/BENCHMARK.md
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID=${2:?--udid requires a value}; shift 2 ;;
    --app) APP_BUNDLE=${2:?--app requires a value}; shift 2 ;;
    --screens) SCREENS_CSV=${2:?--screens requires a value}; shift 2 ;;
    --write) WRITE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in jq xcrun; do
  command -v "$command" >/dev/null 2>&1 || { echo "error: $command is required" >&2; exit 2; }
done

if [[ ! -x "$CLI_BIN" ]]; then
  echo "Building the release CLI..." >&2
  (cd "$CLI_DIR" && swift build -c release)
fi

if [[ -z "$UDID" ]]; then
  UDID=$(xcrun simctl list devices booted -j | jq -r '[.devices[][] | select(.state == "Booted") | .udid][0] // empty')
fi
if [[ -z "$UDID" ]]; then
  echo "error: no booted simulator; pass --udid for a booted device" >&2
  exit 2
fi

IFS=',' read -r -a SCREEN_NAMES <<< "$SCREENS_CSV"
if [[ "${#SCREEN_NAMES[@]}" -ne 4 ]]; then
  echo "error: --screens must contain exactly four comma-separated names" >&2
  exit 2
fi

if ! xcrun simctl get_app_container "$UDID" "$APP_BUNDLE" data >/dev/null 2>&1; then
  TEST_APP_ROOT=""
  for candidate in "$REPO_ROOT/../CosmoKitTestApp" "$REPO_ROOT/../CosmoKit/CosmoKitTestApp"; do
    if [[ -d "$candidate" ]]; then TEST_APP_ROOT="$candidate"; break; fi
  done
  if [[ -z "$TEST_APP_ROOT" ]]; then
    echo "error: $APP_BUNDLE is not installed and CosmoKitTestApp was not found beside the repo" >&2
    exit 2
  fi
  TEST_APP_DERIVED="$REPO_ROOT/.benchmark-test-app-derived-data"
  echo "Building and installing $APP_BUNDLE..." >&2
  xcodebuild -project "$TEST_APP_ROOT/CosmoKitTestApp.xcodeproj" \
    -scheme CosmoKitTestApp -destination "id=$UDID" \
    -derivedDataPath "$TEST_APP_DERIVED" build >/dev/null
  TEST_APP_PATH=$(find "$TEST_APP_DERIVED/Build/Products" -type d -name 'CosmoKitTestApp.app' -print -quit)
  [[ -n "$TEST_APP_PATH" ]] || { echo "error: test app build produced no .app" >&2; exit 1; }
  xcrun simctl install "$UDID" "$TEST_APP_PATH"
fi

"$CLI_BIN" terminate "$APP_BUNDLE" "$UDID" >/dev/null 2>&1 || true
"$CLI_BIN" launch "$APP_BUNDLE" "$UDID" >/dev/null

DRIVER_STARTED=0
DRIVER_START_TIME="already running"
if ! curl -fsS "http://127.0.0.1:8877/tree" | jq -e '.elements' >/dev/null 2>&1; then
  "$CLI_BIN" agent stop "$UDID" >/dev/null 2>&1 || true
  driver_start_file="$TMP_ROOT/driver-start.time"
  /usr/bin/time -p "$CLI_BIN" agent start "$UDID" >/dev/null 2>"$driver_start_file"
  DRIVER_START_TIME="$(awk '$1 == "real" { print $2 }' "$driver_start_file") s"
  DRIVER_STARTED=1
fi

DRIVER_APP=$(curl -fsS "http://127.0.0.1:8877/tree" | jq -r '.app // empty')
if [[ "$DRIVER_APP" != "$APP_BUNDLE" ]]; then
  echo "error: driver inspected '$DRIVER_APP', not requested test app '$APP_BUNDLE'" >&2
  echo "error: the current AgentDriver must honor the --app target before this benchmark can produce valid numbers" >&2
  exit 2
fi

screen_batch() {
  case "$1" in
    home) "$CLI_BIN" ui "do" --app "$APP_BUNDLE" "wait CosmoKit" ;;
    list) "$CLI_BIN" ui "do" --app "$APP_BUNDLE" "swipe up" ;;
    form) "$CLI_BIN" ui "do" --app "$APP_BUNDLE" "swipe up" "swipe up" ;;
    modal) "$CLI_BIN" ui "do" --app "$APP_BUNDLE" "swipe up" "swipe up" "swipe up" ;;
    *) echo "error: unknown screen '$1'; use home,list,form,modal" >&2; return 2 ;;
  esac
}

median() {
  printf '%s\n' "$@" | sort -n | awk 'NR == 3 { print; exit }'
}

measure_command() {
  local output_file=$1
  shift
  local timing_file="$TMP_ROOT/timing.$RANDOM"
  local values=()
  for _ in 1 2 3 4 5; do
    if ! /usr/bin/time -p "$@" >"$output_file" 2>"$timing_file"; then
      cat "$timing_file" >&2
      return 1
    fi
    values+=("$(awk '$1 == "real" { print $2 }' "$timing_file")")
  done
  MEASURE_BYTES=$(wc -c < "$output_file" | tr -d ' ')
  MEASURE_MEDIAN=$(median "${values[@]}")
}

measure_idb() {
  local output_file=$1
  local timing_file="$TMP_ROOT/idb-timing.$RANDOM"
  local values=()
  for _ in 1 2 3 4 5; do
    if ! /usr/bin/time -p idb ui describe-all --udid "$UDID" >"$output_file" 2>"$timing_file"; then
      IDB_AVAILABLE=0
      return 0
    fi
    values+=("$(awk '$1 == "real" { print $2 }' "$timing_file")")
  done
  IDB_AVAILABLE=1
  IDB_BYTES=$(wc -c < "$output_file" | tr -d ' ')
  IDB_MEDIAN=$(median "${values[@]}")
}

tokens() { awk '{ printf "%.0f", $1 / 4 }' <<< "$1"; }
percent() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print "n/a"; else printf "%.1f%%", (1 - a / b) * 100 }'; }

DEVICE_JSON=$(xcrun simctl list devices -j)
DEVICE_NAME=$(jq -r --arg udid "$UDID" '.devices[][] | select(.udid == $udid) | .name' <<< "$DEVICE_JSON")
RUNTIME_ID=$(jq -r --arg udid "$UDID" '.devices | to_entries[] | select(.value[] | .udid == $udid) | .key' <<< "$DEVICE_JSON")
RUNTIME_NAME=$(xcrun simctl list runtimes -j | jq -r --arg id "$RUNTIME_ID" '.runtimes[] | select(.identifier == $id) | .name')
MACOS_VERSION=$(sw_vers -productVersion)
XCODE_VERSION=$(xcodebuild -version | paste -sd ' ' -)
CLI_VERSION=$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$CLI_DIR/Sources/CosmoKitCLI/CLI.swift" | head -1)
TEST_APP_ROOT=${TEST_APP_ROOT:-$REPO_ROOT/../CosmoKit/CosmoKitTestApp}
TEST_APP_COMMIT=$(git -C "$TEST_APP_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)
RUN_COMMAND="bash cli/scripts/benchmark.sh --udid $UDID --app $APP_BUNDLE --screens $SCREENS_CSV --write"

declare -a ACT_BYTES RAW_BYTES IDB_BYTES_LIST SCREEN_HASHES SCREEN_SNIPPETS
REPORT_ROWS=()
for index in 0 1 2 3; do
  screen=${SCREEN_NAMES[$index]}
  echo "Measuring $screen..." >&2
  "$CLI_BIN" terminate "$APP_BUNDLE" "$UDID" >/dev/null 2>&1 || true
  "$CLI_BIN" launch "$APP_BUNDLE" "$UDID" >/dev/null
  screen_batch "$screen" >/dev/null

  act_file="$TMP_ROOT/$screen.act"
  nav_file="$TMP_ROOT/$screen.nav"
  debug_file="$TMP_ROOT/$screen.debug"
  raw_file="$TMP_ROOT/$screen.raw"
  idb_file="$TMP_ROOT/$screen.idb"
  png_file="$TMP_ROOT/$screen.png"

  measure_command "$act_file" "$CLI_BIN" ui tree --mode act --app "$APP_BUNDLE"
  act_bytes=$MEASURE_BYTES; act_time=$MEASURE_MEDIAN

  act_hash=$(grep '^screen: ' "$act_file" | awk '{print $2}' || true)
  if [[ -z "$act_hash" ]]; then
    echo "error: failed to read screen hash for $screen from $act_file" >&2
    exit 1
  fi
  for ((prev=0; prev<index; prev++)); do
    if [[ "${SCREEN_HASHES[prev]}" == "$act_hash" ]]; then
      echo "error: screen '$screen' has same screen hash ($act_hash) as '${SCREEN_NAMES[prev]}'" >&2
      exit 1
    fi
  done
  SCREEN_HASHES[index]=$act_hash
  SCREEN_SNIPPETS[index]=$(head -n 3 "$act_file")

  measure_command "$nav_file" "$CLI_BIN" ui tree --mode nav --app "$APP_BUNDLE"
  nav_bytes=$MEASURE_BYTES
  measure_command "$debug_file" "$CLI_BIN" ui tree --mode debug --app "$APP_BUNDLE"
  debug_bytes=$MEASURE_BYTES
  measure_command "$raw_file" curl -fsS --get --data-urlencode "app=$APP_BUNDLE" http://127.0.0.1:8877/tree
  raw_bytes=$MEASURE_BYTES; raw_time=$MEASURE_MEDIAN
  IDB_AVAILABLE=0; idb_bytes="n/a"; idb_time="n/a"
  if command -v idb >/dev/null 2>&1; then
    measure_idb "$idb_file"
    if [[ "$IDB_AVAILABLE" == "1" ]]; then idb_bytes=$IDB_BYTES; idb_time=$IDB_MEDIAN; fi
  fi
  xcrun simctl io "$UDID" screenshot "$png_file" >/dev/null
  screenshot_bytes=$(stat -f%z "$png_file")

  ACT_BYTES[index]=$act_bytes; RAW_BYTES[index]=$raw_bytes
  if [[ "$idb_bytes" != "n/a" ]]; then IDB_BYTES_LIST[index]=$idb_bytes; else IDB_BYTES_LIST[index]=""; fi
  idb_cell=$idb_bytes
  if [[ "$idb_bytes" != "n/a" ]]; then idb_cell="$idb_bytes ($(tokens "$idb_bytes"))"; fi
  idb_percent="n/a"
  if [[ "$idb_bytes" != "n/a" ]]; then idb_percent=$(percent "$act_bytes" "$idb_bytes"); fi
  REPORT_ROWS[index]="| $screen | $act_bytes ($(tokens "$act_bytes")) | $nav_bytes ($(tokens "$nav_bytes")) | $debug_bytes ($(tokens "$debug_bytes")) | $raw_bytes ($(tokens "$raw_bytes")) | $idb_cell | $screenshot_bytes | $(percent "$act_bytes" "$raw_bytes") | $idb_percent | $act_time | $raw_time | $idb_time |"
done

mean_percent() {
  local kind=$1
  awk -v kind="$kind" 'BEGIN { total=0; count=0 } {
    a=$1; b=$2; if (b > 0) { total += (1 - a / b) * 100; count++ }
  } END { if (count == 0) print "n/a"; else printf "%.1f%%", total / count }' "$TMP_ROOT/percent.$kind"
}

: > "$TMP_ROOT/percent.raw"
: > "$TMP_ROOT/percent.idb"
for index in 0 1 2 3; do
  echo "${ACT_BYTES[$index]} ${RAW_BYTES[$index]}" >> "$TMP_ROOT/percent.raw"
  if [[ -n "${IDB_BYTES_LIST[$index]}" ]]; then echo "${ACT_BYTES[$index]} ${IDB_BYTES_LIST[$index]}" >> "$TMP_ROOT/percent.idb"; fi
done
MEAN_RAW=$(mean_percent raw)
MEAN_IDB=$(mean_percent idb)

IDB_HEADER="not installed"
if command -v idb >/dev/null 2>&1; then
  IDB_HEADER="installed"
fi

APPENDIX_SNIPPETS=""
for ((idx=0; idx<4; idx++)); do
  sname="${SCREEN_NAMES[idx]}"
  shash="${SCREEN_HASHES[idx]}"
  ssnip="${SCREEN_SNIPPETS[idx]}"
  APPENDIX_SNIPPETS+=$'\n'"### $sname (hash: $shash)"$'\n\n'
  APPENDIX_SNIPPETS+='```'$'\n'
  APPENDIX_SNIPPETS+="$ssnip"$'\n'
  APPENDIX_SNIPPETS+='```'$'\n'
done

REPORT=$(cat <<EOF
# CosmoKit UI tree benchmark

- Date (UTC): $(date -u +%Y-%m-%d)
- macOS: $MACOS_VERSION
- Xcode: $XCODE_VERSION
- Simulator: $DEVICE_NAME ($UDID), $RUNTIME_NAME
- CLI version: $CLI_VERSION
- Driver start: $DRIVER_START_TIME
- Test app commit: $TEST_APP_COMMIT
- idb: $IDB_HEADER
- Reproduce: \`$RUN_COMMAND\`

Bytes are UTF-8 output bytes. Tokens are approximate bytes ÷ 4, matching the
README convention; this is not a tokenizer-exact count. Timing is the median
of five runs and is wall-clock \`real\` time.

| Screen | act bytes (≈ tokens) | nav bytes (≈ tokens) | debug bytes (≈ tokens) | raw driver JSON bytes (≈ tokens) | idb bytes (≈ tokens) | screenshot PNG bytes | act vs raw | act vs idb | act median (s) | raw median (s) | idb median (s) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
$(printf '%s\n' "${REPORT_ROWS[@]}")
| **Mean** | — | — | — | — | — | — | **$MEAN_RAW** | **$MEAN_IDB** | — | — | — |

The quoted percentages are for this four-screen test app run on this date:
act vs raw driver JSON = $MEAN_RAW; act vs idb = $MEAN_IDB.

## Appendix: First 3 lines of act output per screen
$APPENDIX_SNIPPETS
EOF
)

printf '%s\n' "$REPORT"
if [[ "$WRITE" == "1" ]]; then
  printf '%s\n' "$REPORT" > "$REPO_ROOT/cli/BENCHMARK.md"
  echo "Wrote $REPO_ROOT/cli/BENCHMARK.md" >&2
fi
