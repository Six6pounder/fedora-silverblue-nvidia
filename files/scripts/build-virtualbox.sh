#!/usr/bin/env bash

# Build the VirtualBox host kernel modules (vboxdrv, vboxnetflt, vboxnetadp)
# against the kernel shipped in this image so they are baked in and ready at
# first boot. There is no official VirtualBox Flatpak (it requires host kernel
# modules) and VirtualBox is not part of the prebuilt ublue-os/akmods set, so we
# compile it ourselves here. RPMFusion (free) is enabled by the dnf module
# earlier in the recipe.
#
# The tricky part: akmod-VirtualBox's %post scriptlet runs `akmods` as root, and
# akmods/akmodsbuild refuse to run when "/" is writable (i.e. as root). In the
# build container that scriptlet fails and aborts the whole dnf transaction. So
# we never install akmod-VirtualBox at all. Instead we extract its kmod source
# rpm, compile it as an unprivileged user, install the resulting kmod-VirtualBox
# package, and only then install the VirtualBox userspace (whose kernel-module
# dependency is now already satisfied, so akmod-VirtualBox is not pulled in).

set -euo pipefail

# shellcheck source=./lib-kernel-devel.sh
source "$(dirname "$(readlink -f "$0")")/lib-kernel-devel.sh"

# Resolve the exact kernel version baked into the image (NOT the build host's
# `uname -r`, which would be wrong inside the build container).
KERNEL_VERSION="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
echo "Building VirtualBox kernel modules for ${KERNEL_VERSION}"

# Build prerequisites. VirtualBox-kmodsrc carries the actual module source that
# the kmod src.rpm BuildRequires; none of these pull in akmod-VirtualBox.
# kernel-devel goes first and on its own: akmods requires kernel-devel-matched
# for the running kernel, which is only installable once that exact version is
# available (see lib-kernel-devel.sh).
install_kernel_devel "${KERNEL_VERSION}"
dnf5 install -y \
  akmods \
  cpio \
  VirtualBox-kmodsrc

# Fetch akmod-VirtualBox and extract only its kmod source rpm, without
# installing the package (which would trigger the failing %post).
WORKDIR="$(mktemp -d)"
( cd "${WORKDIR}" && dnf5 download akmod-VirtualBox && rpm2cpio akmod-VirtualBox-*.rpm | cpio -idm )
SRPM="$(ls "${WORKDIR}"/usr/src/akmods/VirtualBox-kmod-*.src.rpm | head -1)"

# Compile the kmod as an unprivileged user (the akmods package creates no build
# user, so make a throwaway one). The output dir must be owned by that user.
# akmodsbuild hard-codes /tmp for its build tree and rpmbuild creates its helper
# scripts in /var/tmp.  The BlueBuild stage can inherit both directories as
# root-only, so restore their normal shared-temporary-directory permissions
# before dropping privileges.
chmod 1777 /tmp /var/tmp

if ! getent passwd akmodsbuild >/dev/null; then
  useradd -r -m -d /var/lib/akmodsbuild -s /usr/sbin/nologin akmodsbuild
fi
OUTDIR="$(mktemp -d)"
cp "${SRPM}" "${OUTDIR}/"
chown -R akmodsbuild: "${OUTDIR}"

runuser -u akmodsbuild -- \
  akmodsbuild --kernels "${KERNEL_VERSION}" --outputdir "${OUTDIR}" \
  "${OUTDIR}/$(basename "${SRPM}")"

# Install the freshly built kmod, then the VirtualBox userspace.
dnf5 install -y "${OUTDIR}"/kmod-VirtualBox-*.rpm
dnf5 install -y --setopt=install_weak_deps=False VirtualBox
rm -rf "${WORKDIR}" "${OUTDIR}"

# Fail the build loudly if the module did not actually get installed.
depmod -a "${KERNEL_VERSION}"
modinfo -k "${KERNEL_VERSION}" vboxdrv >/dev/null

echo "VirtualBox kernel modules built successfully for ${KERNEL_VERSION}"
