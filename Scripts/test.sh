#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${TMPDIR:-/tmp/}MKVStudio-tests"
export CLANG_MODULE_CACHE_PATH="$CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/modules"
swift test --package-path "$ROOT" --scratch-path "$CACHE/products" --cache-path "$CACHE/cache" --config-path "$CACHE/config" --security-path "$CACHE/security" --disable-sandbox --build-system native
