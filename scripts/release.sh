#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$CLI_DIR"

ALLOW_DIRTY=0
for arg in "$@"; do
    if [[ "$arg" == "--allow-dirty" ]]; then
        ALLOW_DIRTY=1
    fi
done

# 1. Read version from CLI.swift
VERSION_FILE="Sources/CosmoKitCLI/CLI.swift"
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "Error: cannot find $VERSION_FILE" >&2
    exit 1
fi
VERSION=$(grep -E 'public static let version = "([0-9]+\.[0-9]+\.[0-9]+)"' "$VERSION_FILE" | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$VERSION" ]]; then
    echo "Error: failed to extract version from $VERSION_FILE" >&2
    exit 1
fi
echo "==> Packaging cosmokit $VERSION"

# 2. Refuse to run if git status --porcelain cli/ is not clean
REPO_ROOT="$(git rev-parse --show-toplevel)"
STATUS_OUTPUT=$(git -C "$REPO_ROOT" status --porcelain cli/)
if [[ "$ALLOW_DIRTY" -eq 0 && -n "$STATUS_OUTPUT" ]]; then
    echo "Error: working directory has uncommitted changes in cli/:" >&2
    echo "$STATUS_OUTPUT" >&2
    echo "Commit changes first or pass --allow-dirty for test runs." >&2
    exit 1
fi

# 3. Build universal binary (arm64 + x86_64)
echo "==> Building universal binary (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

BIN_SOURCE=".build/apple/Products/Release/cosmokit"
if [[ ! -f "$BIN_SOURCE" ]]; then
    echo "Error: built binary not found at $BIN_SOURCE" >&2
    exit 1
fi

LIPO_INFO=$(lipo -info "$BIN_SOURCE")
echo "$LIPO_INFO"
if [[ "$LIPO_INFO" != *"arm64"* ]] || [[ "$LIPO_INFO" != *"x86_64"* ]]; then
    echo "Error: binary is not universal (expected arm64 and x86_64): $LIPO_INFO" >&2
    exit 1
fi

# 4. Ad-hoc codesign
echo "==> Ad-hoc codesigning binary..."
codesign -s - --force "$BIN_SOURCE"

# 5. Stage distribution directory
DIST_DIR="dist"
STAGE_DIR="$DIST_DIR/cosmokit-$VERSION-macos-universal"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/bin"
mkdir -p "$STAGE_DIR/share/cosmokit/Driver"

cp "$BIN_SOURCE" "$STAGE_DIR/bin/cosmokit"
chmod +x "$STAGE_DIR/bin/cosmokit"

rsync -a \
    --exclude '.DS_Store' \
    --exclude 'xcuserdata' \
    --exclude '*.xcworkspace/xcuserdata' \
    --exclude 'smoke.sh' \
    Driver/ "$STAGE_DIR/share/cosmokit/Driver/"

# 6. Create tarball
ARCHIVE_NAME="cosmokit-$VERSION-macos-universal.tar.gz"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
rm -f "$ARCHIVE_PATH"

tar czf "$ARCHIVE_PATH" -C "$STAGE_DIR" .

ABS_ARCHIVE_PATH="$(cd "$DIST_DIR" && pwd)/$ARCHIVE_NAME"
echo "==> Release archive:"
shasum -a 256 "$ARCHIVE_PATH"
echo "$ABS_ARCHIVE_PATH"

# 7. Smoke test
echo "==> Running smoke test from temporary directory..."
SMOKE_TMP=$(mktemp -d)
trap 'rm -rf "$SMOKE_TMP"' EXIT

tar xzf "$ARCHIVE_PATH" -C "$SMOKE_TMP"

SMOKE_VERSION=$("$SMOKE_TMP/bin/cosmokit" version)
echo "Smoke version: $SMOKE_VERSION"
if [[ "$SMOKE_VERSION" != "$VERSION" ]]; then
    echo "Smoke test failed: expected version '$VERSION', got '$SMOKE_VERSION'" >&2
    exit 1
fi

DOCTOR_JSON=$(cd / && "$SMOKE_TMP/bin/cosmokit" doctor --json)
echo "Smoke doctor JSON: $DOCTOR_JSON"

RESOLVED_DRIVER=$(echo "$DOCTOR_JSON" | jq -r '.checks[] | select(.name=="driver sources") | .detail')
EXPECTED_DRIVER="$SMOKE_TMP/share/cosmokit/Driver"

RESOLVED_REAL=$(cd "$RESOLVED_DRIVER" 2>/dev/null && pwd -P || echo "$RESOLVED_DRIVER")
EXPECTED_REAL=$(cd "$EXPECTED_DRIVER" 2>/dev/null && pwd -P || echo "$EXPECTED_DRIVER")

if [[ "$RESOLVED_REAL" != "$EXPECTED_REAL" ]]; then
    echo "Smoke test failed: doctor driver sources resolved to '$RESOLVED_REAL', expected '$EXPECTED_REAL'" >&2
    exit 1
fi

echo "Smoke test passed: driver sources resolved to $RESOLVED_DRIVER"
