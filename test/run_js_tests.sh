#!/bin/sh
# OpenWardRivingT — JS test runner.
# Run: sh test/run_js_tests.sh
# Requires: node (>= 18 for node --test)
#
# This wraps Node's built-in test runner. We don't pull in jest/vitest
# just for one test file: the helpers in app-utils.js are pure string/
# option manipulation, so a DOM shim is not needed.

set -e
cd "$(dirname "$0")/.."

if ! command -v node >/dev/null 2>&1; then
    echo "  ⚠ node not found; skipping JS tests"
    exit 0
fi

# Pin to the LTS API surface we depend on. node --test shipped in
# v18 stable, so this works on anything recent.
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
if [ "$NODE_MAJOR" -lt 18 ]; then
    echo "  ⚠ node < 18 (found $NODE_MAJOR); skipping JS tests"
    exit 0
fi

exec node --test test/js/app-utils.test.js
