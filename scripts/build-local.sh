#!/bin/bash
# build-local.sh — Build DEB or RPM packages locally using Docker
#
# Usage:
#   ./scripts/build-local.sh deb debian:13
#   ./scripts/build-local.sh deb ubuntu:24.04
#   ./scripts/build-local.sh rpm rockylinux:9
#   ./scripts/build-local.sh rpm fedora:44
#   ./scripts/build-local.sh rpm amazonlinux:2023
#
# Optional: add "test" as third argument to also run the test script:
#   ./scripts/build-local.sh deb debian:12 test
#   ./scripts/build-local.sh rpm almalinux:9 test
set -euo pipefail

PKG_TYPE="${1:-}"
IMAGE="${2:-}"
RUN_TEST="${3:-}"

if [ -z "$PKG_TYPE" ] || [ -z "$IMAGE" ]; then
    echo "Usage: $0 <deb|rpm> <docker-image> [test]"
    echo ""
    echo "Examples:"
    echo "  $0 deb debian:13"
    echo "  $0 deb ubuntu:24.04"
    echo "  $0 rpm rockylinux:9"
    echo "  $0 rpm fedora:44"
    echo "  $0 rpm amazonlinux:2023"
    echo "  $0 deb debian:12 test    # build + test"
    exit 1
fi

# Find repo root
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Initialize submodule if needed
if [ ! -f deps/luajit/Makefile ]; then
    echo "==> Initializing LuaJIT submodule..."
    git submodule update --init --recursive
fi

# Determine version
VERSION=$(cat VERSION | tr -d '[:space:]')
GIT_SHA=$(git rev-parse --short HEAD)
if [[ "$VERSION" = *-dev ]]; then
    VERSION="${VERSION}+${GIT_SHA}"
fi

echo "==> Version: ${VERSION}"
echo "==> Image:   ${IMAGE}"
echo "==> Type:    ${PKG_TYPE}"

# Create temp dirs
TMPDIR=$(mktemp -d)
SOURCE_DIR="${TMPDIR}/source"
OUTPUT_DIR="${TMPDIR}/output"
mkdir -p "$SOURCE_DIR" "$OUTPUT_DIR"

trap "echo '==> Packages in: ${OUTPUT_DIR}'" EXIT

# Create source tarball
echo "==> Creating source tarball..."
SRCDIR="${TMPDIR}/valkey-luajit-${VERSION}"
mkdir -p "$SRCDIR"
rsync -a --exclude='.git' src/ "$SRCDIR/src/"
rsync -a --exclude='.git' deps/ "$SRCDIR/deps/"
rsync -a --exclude='.git' cmake/ "$SRCDIR/cmake/"
cp CMakeLists.txt valkeyluajit.map README.md LICENSE VERSION "$SRCDIR/"
tar czf "$SOURCE_DIR/valkey-luajit-${VERSION}.tar.gz" -C "$TMPDIR" "valkey-luajit-${VERSION}"

# Determine platform parameters
case "$PKG_TYPE" in
    deb)
        case "$IMAGE" in
            debian:11*)  CODENAME="bullseye"; PLATFORM_ID="debian-11" ;;
            debian:12*)  CODENAME="bookworm"; PLATFORM_ID="debian-12" ;;
            debian:13*)  CODENAME="trixie";   PLATFORM_ID="debian-13" ;;
            ubuntu:22*)  CODENAME="jammy";    PLATFORM_ID="ubuntu-22.04" ;;
            ubuntu:24*)  CODENAME="noble";    PLATFORM_ID="ubuntu-24.04" ;;
            *)           CODENAME="unstable"; PLATFORM_ID="unknown" ;;
        esac
        ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
        echo "==> Building DEB for ${PLATFORM_ID} (${CODENAME}) ${ARCH}"
        docker run --rm \
            -e PLATFORM_ID="$PLATFORM_ID" \
            -e PLATFORM_CODENAME="$CODENAME" \
            -e EXPECTED_ARCH="$ARCH" \
            -e MODULE_VERSION="$VERSION" \
            -v "$SOURCE_DIR:/source:ro" \
            -v "$REPO_ROOT/packaging:/packaging:ro" \
            -v "$REPO_ROOT/scripts:/scripts:ro" \
            -v "$OUTPUT_DIR:/output" \
            "$IMAGE" \
            bash /scripts/build-container-deb.sh
        ;;
    rpm)
        case "$IMAGE" in
            fedora:*)      FAMILY="fedora" ;;
            opensuse*)     FAMILY="suse" ;;
            *)             FAMILY="rhel" ;;
        esac
        PLATFORM_ID=$(echo "$IMAGE" | tr ':/' '-')
        ARCH=$(uname -m)
        PKG_NAME="valkey-luajit-nightly"
        if [[ "$VERSION" != *-dev* ]]; then
            PKG_NAME="valkey-luajit"
        fi
        echo "==> Building RPM for ${PLATFORM_ID} (${FAMILY}) ${ARCH}"
        docker run --rm \
            -e PLATFORM_FAMILY="$FAMILY" \
            -e PLATFORM_ID="$PLATFORM_ID" \
            -e EXPECTED_ARCH="$ARCH" \
            -e MODULE_VERSION="$VERSION" \
            -e PKG_NAME="$PKG_NAME" \
            -v "$SOURCE_DIR:/source:ro" \
            -v "$REPO_ROOT/packaging:/packaging:ro" \
            -v "$REPO_ROOT/scripts:/scripts:ro" \
            -v "$OUTPUT_DIR:/output" \
            "$IMAGE" \
            bash /scripts/build-container-rpm.sh
        ;;
    *)
        echo "ERROR: Unknown package type: ${PKG_TYPE}. Use 'deb' or 'rpm'." >&2
        exit 1
        ;;
esac

echo ""
echo "==> Built packages:"
ls -lh "$OUTPUT_DIR"/*

# Run tests if requested
if [ "$RUN_TEST" = "test" ]; then
    echo ""
    echo "==> Running tests..."
    if [ "$PKG_TYPE" = "deb" ]; then
        PKG_FILE=$(ls "$OUTPUT_DIR"/*.deb | grep -v dbgsym | head -1 | xargs basename)
        EXPECTED="$ARCH"
    else
        PKG_FILE=$(ls "$OUTPUT_DIR"/*.rpm | grep -v '\.src\.rpm$' | head -1 | xargs basename)
        EXPECTED="$ARCH"
    fi
    docker run --rm \
        -e PACKAGE_FILE="$PKG_FILE" \
        -e EXPECTED_ARCH="$EXPECTED" \
        -v "$OUTPUT_DIR:/packages:ro" \
        -v "$REPO_ROOT/scripts:/scripts:ro" \
        "$IMAGE" \
        bash /scripts/test-module-package.sh
fi
