#!/usr/bin/env bash

# Build the VirtualBox host kernel modules (vboxdrv, vboxnetflt, vboxnetadp)
# against the kernel shipped in this image so they are baked in and ready at
# first boot. There is no official VirtualBox Flatpak (it requires host kernel
# modules) and VirtualBox is not part of the prebuilt ublue-os/akmods set, so we
# compile it ourselves here. RPMFusion (free) is enabled by the dnf module
# earlier in the recipe.

set -euo pipefail

# Resolve the exact kernel version baked into the image (NOT the build host's
# `uname -r`, which would be wrong inside the build container).
KERNEL_VERSION="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
echo "Building VirtualBox kernel modules for ${KERNEL_VERSION}"

# Install build prerequisites + VirtualBox userspace (pulls in akmod-VirtualBox,
# which ships the kmod source rpm under /usr/src/akmods).
dnf5 install -y \
  "kernel-devel-${KERNEL_VERSION}" \
  akmods \
  VirtualBox

# akmods/akmodsbuild refuse to run when "/" is writable (i.e. as root), and the
# build container is root. So compile the kmod RPM as an unprivileged user, then
# install the resulting RPM as root. The akmods package does not create a build
# user, so make a throwaway one.
if ! getent passwd akmodsbuild >/dev/null; then
  useradd -r -m -d /var/lib/akmodsbuild -s /usr/sbin/nologin akmodsbuild
fi

SRPM="$(ls /usr/src/akmods/VirtualBox-kmod-*.src.rpm | head -1)"
OUTDIR="$(mktemp -d)"
chown -R akmodsbuild: "${OUTDIR}"

runuser -u akmodsbuild -- \
  akmodsbuild --kernels "${KERNEL_VERSION}" --outputdir "${OUTDIR}" "${SRPM}"

# Install the freshly built kmod RPM into the image.
dnf5 install -y "${OUTDIR}"/kmod-VirtualBox-*.rpm
rm -rf "${OUTDIR}"

# Fail the build loudly if the module did not actually get installed.
depmod -a "${KERNEL_VERSION}"
modinfo -k "${KERNEL_VERSION}" vboxdrv >/dev/null

echo "VirtualBox kernel modules built successfully for ${KERNEL_VERSION}"
