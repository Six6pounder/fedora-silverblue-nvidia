#!/usr/bin/env bash

# Build the xone kernel modules (Xbox One/Series controllers + the GIP wireless
# dongle) against the kernel shipped in this image so they are baked in and
# ready at first boot. xone is an out-of-tree DKMS driver; on an atomic image
# there is no runtime DKMS rebuild, so we compile it here (same approach as
# build-virtualbox.sh) and ship the resulting .ko files in /usr/lib/modules.
#
# Source: https://github.com/medusalix/xone
#
# NOTE: upstream medusalix/xone can lag behind newer kernels. If the build below
# fails to compile against this image's kernel, switch XONE_REPO to the
# community-maintained fork https://github.com/dlundqvist/xone (drop-in, same
# layout) and pin XONE_COMMIT to one of its commits.

set -euo pipefail

# Pin to a specific upstream commit for reproducible builds. v0.3 tag.
XONE_REPO="https://github.com/medusalix/xone.git"
XONE_COMMIT="8311a25f2b4e69b7a3f8133b884cede065b253cc"
XONE_VERSION="0.3"

# Resolve the exact kernel version baked into the image (NOT the build host's
# `uname -r`, which would be wrong inside the build container).
KERNEL_VERSION="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
echo "Building xone kernel modules for ${KERNEL_VERSION}"

# Build prerequisites. cabextract is needed at *runtime* by xone-get-firmware.sh
# (the wireless dongle's firmware is non-redistributable and must be fetched by
# the user post-install), so we install it now to bake it into the image.
dnf5 install -y \
  "kernel-devel-${KERNEL_VERSION}" \
  dkms \
  gcc \
  make \
  git \
  cabextract

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
dkms build -m xone -v "${XONE_VERSION}" -k "${KERNEL_VERSION}"
dkms install -m xone -v "${XONE_VERSION}" -k "${KERNEL_VERSION}"

# xone replaces the in-tree xpad driver and conflicts with mt76x2u on the
# dongle, so blacklist both. Use /usr/lib/modprobe.d (image-owned, read-only)
# rather than /etc so it ships with the image.
install -D -m 644 "${SRC}/install/modprobe.conf" \
  /usr/lib/modprobe.d/xone-blacklist.conf

# Firmware helper for the wireless dongle. Non-redistributable, so this just
# downloads + extracts Microsoft's firmware; the user runs it once post-install.
install -D -m 755 "${SRC}/install/firmware.sh" \
  /usr/bin/xone-get-firmware.sh

# Fail the build loudly if the modules did not actually get installed.
depmod -a "${KERNEL_VERSION}"
modinfo -k "${KERNEL_VERSION}" xone-gip >/dev/null
modinfo -k "${KERNEL_VERSION}" xone-dongle >/dev/null

echo "xone kernel modules built successfully for ${KERNEL_VERSION}"
