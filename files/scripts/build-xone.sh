#!/usr/bin/env bash

# Build the xone kernel modules (Xbox One/Series controllers + the GIP wireless
# dongle) against the kernel shipped in this image so they are baked in and
# ready at first boot. xone is an out-of-tree DKMS driver; on an atomic image
# there is no runtime DKMS rebuild, so we compile it here (same approach as
# build-virtualbox.sh) and ship the resulting .ko files in /usr/lib/modules.
#
# Source: https://github.com/dlundqvist/xone
#
# NOTE: we use the community-maintained dlundqvist/xone fork, not upstream
# medusalix/xone. Upstream is stale (v0.3) and does NOT compile against recent
# kernels (it failed on this image's 7.0.x kernel). The fork is a drop-in with
# the same layout and tracks new kernels. If a future kernel breaks the build,
# bump XONE_COMMIT/XONE_VERSION to a newer tag from that repo.

set -euo pipefail

# shellcheck source=./lib-kernel-devel.sh
source "$(dirname "$(readlink -f "$0")")/lib-kernel-devel.sh"

# Pin to a specific tag for reproducible builds. dlundqvist/xone v0.5.8.
XONE_REPO="https://github.com/dlundqvist/xone.git"
XONE_COMMIT="f2aa9fe01103d7600553b505b298ff0bd47ff280"
XONE_VERSION="0.5.8"

# Resolve the exact kernel version baked into the image (NOT the build host's
# `uname -r`, which would be wrong inside the build container).
KERNEL_VERSION="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
echo "Building xone kernel modules for ${KERNEL_VERSION}"

# Build prerequisites. bsdtar (libarchive) is needed at *runtime* by
# xone-get-firmware.sh -- the fork's firmware script extracts the dongle firmware
# cab with bsdtar, not cabextract -- so we bake it into the image. The firmware
# itself is non-redistributable and is fetched by the user post-install.
install_kernel_devel "${KERNEL_VERSION}"
dnf5 install -y \
  dkms \
  gcc \
  make \
  git \
  bsdtar

# Fetch the pinned source into the DKMS source tree.
SRC="/usr/src/xone-${XONE_VERSION}"
rm -rf "${SRC}"
git clone "${XONE_REPO}" "${SRC}"
( cd "${SRC}" && git checkout --quiet "${XONE_COMMIT}" )

# dkms.conf ships PACKAGE_VERSION as a "#VERSION#" placeholder that upstream's
# install.sh rewrites at install time; do the same so it matches our -v value.
sed -i "s/#VERSION#/${XONE_VERSION}/" "${SRC}/dkms.conf"

# Build + install against the image's kernel specifically. dkms copies the
# resulting modules into /lib/modules/${KERNEL_VERSION}/ (= /usr/lib/modules on
# Fedora), which is part of the image; the /var/lib/dkms build state is not, but
# we don't need it at runtime since the modules are prebuilt.
dkms add -m xone -v "${XONE_VERSION}"
# On a build failure, surface the compiler's make.log before exiting -- otherwise
# dkms just says "Bad return status" and the real error is buried in a file that
# does not survive the container.
if ! dkms build -m xone -v "${XONE_VERSION}" -k "${KERNEL_VERSION}"; then
  echo "=== xone dkms build FAILED; dumping make.log ===" >&2
  cat "/var/lib/dkms/xone/${XONE_VERSION}/build/make.log" >&2 || true
  exit 1
fi
dkms install -m xone -v "${XONE_VERSION}" -k "${KERNEL_VERSION}"

# xone replaces the in-tree xpad driver and conflicts with mt76x2u on the
# dongle, so blacklist both. Use /usr/lib/modprobe.d (image-owned, read-only)
# rather than /etc so it ships with the image.
install -D -m 644 "${SRC}/install/modprobe.conf" \
  /usr/lib/modprobe.d/xone-blacklist.conf

# Firmware helper for the wireless dongle. Non-redistributable, so this just
# downloads + extracts Microsoft's firmware; the user runs it once post-install.
# Redirect its write target from /lib/firmware (read-only on atomic) to the
# writable /var/lib/firmware, which the kernel searches via the firmware_class.path
# karg shipped in files/system/usr/lib/bootc/kargs.d/xone-firmware.toml.
install -D -m 755 "${SRC}/install/firmware.sh" \
  /usr/bin/xone-get-firmware.sh
sed -i 's#"/lib/firmware/#"/var/lib/firmware/#g' /usr/bin/xone-get-firmware.sh
grep -q '/var/lib/firmware/' /usr/bin/xone-get-firmware.sh  # fail build if the patch didn't apply

# Fail the build loudly if the modules did not actually get installed.
depmod -a "${KERNEL_VERSION}"
modinfo -k "${KERNEL_VERSION}" xone-gip >/dev/null
modinfo -k "${KERNEL_VERSION}" xone-dongle >/dev/null

echo "xone kernel modules built successfully for ${KERNEL_VERSION}"
