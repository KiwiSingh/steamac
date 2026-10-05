#!/usr/bin/env bash
# Compiles production Gamepad code with stubs for the VM transport/settings.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$ROOT/work"
TEST_DIR=$(mktemp -d "$ROOT/work/controller-test.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
export TMPDIR="$TEST_DIR"
compiler=${SWIFTC:-$(xcrun --find swiftc)}
sdk=${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}
cp "$ROOT/scripts/test/controller-check.swift" "$TEST_DIR/main.swift"
"$compiler" -sdk "$sdk" -module-cache-path "$ROOT/work/swift-cache" \
    "$ROOT/host/launcher/Sources/steamac-vm/LinuxInput.swift" \
    "$ROOT/host/launcher/Sources/steamac-vm/Gamepad.swift" \
    "$TEST_DIR/main.swift" -o "$TEST_DIR/check"
"$TEST_DIR/check"
