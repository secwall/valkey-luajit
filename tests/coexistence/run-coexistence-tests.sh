#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
VALKEY_DIR="$REPO_ROOT/build/valkey"
LUAJIT_MODULE="$REPO_ROOT/build/libvalkeyluajit.so"

if [ ! -f "$VALKEY_DIR/runtest" ]; then
    echo "Error: Valkey test runner not found at $VALKEY_DIR/runtest"
    echo ""
    echo "Please build the project first:"
    echo "  BUILD_LUA=yes ./build.sh --with-tests"
    exit 1
fi

if [ ! -f "$LUAJIT_MODULE" ]; then
    echo "Error: LuaJIT module not found at $LUAJIT_MODULE"
    echo ""
    echo "Please build the project first:"
    echo "  ./build.sh"
    exit 1
fi

echo "Running coexistence tests (LuaJIT + built-in Lua)..."
echo "Valkey:  $VALKEY_DIR"
echo "Module:  $LUAJIT_MODULE"
echo "Engine name: LUAJIT"
echo ""

EXTRA_SKIP_ARGS=(
    "--skiptest" "/FUNCTION - function stats"
    "--skiptest" "/FUNCTION - test function stats"
    "--skiptest" "CONFIG sanity"
)

# Copy coexistence tests
cp "$SCRIPT_DIR"/*.tcl "$VALKEY_DIR/tests/unit/"

cd "$VALKEY_DIR"
./runtest --config loadmodule "$LUAJIT_MODULE" "${EXTRA_SKIP_ARGS[@]}" --config luajit.engine-name LUAJIT "$@"
