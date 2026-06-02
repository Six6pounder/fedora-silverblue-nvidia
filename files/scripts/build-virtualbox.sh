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

# Install build prerequisites + VirtualBox userspace (pulls in akmod-VirtualBox).
dnf5 install -y \
  "kernel-devel-${KERNEL_VERSION}" \
  akmods \
  VirtualBox

# Force-compile the module set for the image kernel. The akmod %post that runs
# during install is effectively a no-op in a build container, so do it
# explicitly here.
akmods --force --kernels "${KERNEL_VERSION}" --kmod VirtualBox

# Fail the build loudly if the module did not actually get produced/installed.
depmod -a "${KERNEL_VERSION}"
modinfo -k "${KERNEL_VERSION}" vboxdrv >/dev/null

# Drop the build-only kernel headers so they don't bloat the final image; the
# compiled .ko files are already installed under /usr/lib/modules.
dnf5 remove -y "kernel-devel-${KERNEL_VERSION}" || true

echo "VirtualBox kernel modules built successfully for ${KERNEL_VERSION}"
