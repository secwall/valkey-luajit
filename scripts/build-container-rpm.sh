#!/bin/bash
# build-container-rpm.sh — Build RPM packages inside a container
#
# Expected env vars:
#   PLATFORM_FAMILY  — "fedora" or "rhel"
#   PLATFORM_ID      — e.g. "rockylinux-9", "fedora-44"
#   EXPECTED_ARCH    — "x86_64" or "aarch64"
#   MODULE_VERSION   — e.g. "0.1.0" or "0.1.0-dev+abc1234"
#   PKG_NAME         — "valkey-luajit" or "valkey-luajit-nightly"
#
# Expected mounts:
#   /source    — source tarball (valkey-luajit-VERSION.tar.gz)
#   /packaging — packaging/ directory from repo
#   /scripts   — scripts/ directory from repo
#   /output    — directory for built RPMs
set -euo pipefail

echo "==> Building RPM for ${PKG_NAME} ${MODULE_VERSION} on ${PLATFORM_ID} (${EXPECTED_ARCH})"

# ── Step 1: Install system build dependencies ──
if [ "${PLATFORM_FAMILY}" = "fedora" ]; then
    dnf install -y \
        rpm-build rpmdevtools \
        gcc cmake make \
        tar gzip
else
    # RHEL-family (Rocky, Alma, Oracle, Amazon)
    if command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    else
        PKG_MGR="yum"
    fi
    $PKG_MGR install -y epel-release 2>/dev/null || true
    $PKG_MGR install -y --allowerasing \
        rpm-build rpmdevtools \
        gcc cmake make \
        tar gzip
fi

# ── Step 2: Set up rpmbuild tree ──
rpmdev-setuptree

RPM_VERSION=$(echo "$MODULE_VERSION" | tr - '~')

# ── Step 3: Generate spec from template ──
sed -e "s/#\[RPM_VERSION\]/${RPM_VERSION}/g" \
    -e "s/#\[VERSION\]/${MODULE_VERSION}/g" \
    -e "s/#\[PKG_NAME\]/${PKG_NAME}/g" \
    /packaging/valkey-luajit.spec.in > ~/rpmbuild/SPECS/${PKG_NAME}.spec

# Append changelog entry
DATE=$(LC_TIME=en_US.UTF-8 date "+%a %b %d %Y")
cat >> ~/rpmbuild/SPECS/${PKG_NAME}.spec <<EOF
* ${DATE} Valkey Contributors <valkey@lists.valkey.io> - ${RPM_VERSION}
- Update to upstream version ${MODULE_VERSION}
EOF

# ── Step 4: Copy source tarball ──
cp /source/valkey-luajit-${MODULE_VERSION}.tar.gz ~/rpmbuild/SOURCES/

# ── Step 5: Build ──
echo "==> Running rpmbuild"
rpmbuild -ba ~/rpmbuild/SPECS/${PKG_NAME}.spec

# ── Step 6: Sanity checks ──
echo "==> Sanity checks"
RPM_FILE=$(find ~/rpmbuild/RPMS/ -name "*.rpm" -not -name "*.src.rpm" | head -1)
if [ -z "$RPM_FILE" ]; then
    echo "ERROR: No RPM produced!" >&2
    exit 1
fi

# Check the .so is inside (capture output to avoid SIGPIPE with pipefail)
RPM_CONTENTS=$(rpm -qlp "$RPM_FILE" || true)
if ! echo "$RPM_CONTENTS" | grep -q 'libvalkeyluajit.so'; then
    echo "ERROR: libvalkeyluajit.so not found in RPM!" >&2
    exit 1
fi

# Check architecture
RPM_ARCH=$(rpm -qp --queryformat '%{ARCH}' "$RPM_FILE")
if [ "$RPM_ARCH" != "$EXPECTED_ARCH" ]; then
    echo "ERROR: Expected arch ${EXPECTED_ARCH}, got ${RPM_ARCH}" >&2
    exit 1
fi

echo "==> RPM built successfully: $(basename "$RPM_FILE")"

# ── Step 7: Copy RPMs to output ──
cp ~/rpmbuild/RPMS/*/*.rpm /output/
cp ~/rpmbuild/SRPMS/*.rpm /output/ 2>/dev/null || true

echo "==> Output:"
ls -la /output/*.rpm
