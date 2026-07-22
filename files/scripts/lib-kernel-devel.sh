#!/usr/bin/env bash

# Shared helper for the out-of-tree kernel module builds (build-virtualbox.sh,
# build-xone.sh). Not listed in any recipe -- it is only meant to be sourced.
#
# Installs kernel-devel (and kernel-devel-matched) for the *exact* kernel baked
# into the image.
#
# The base image regularly ships a kernel that has already been superseded in
# the Fedora repos: e.g. the image carries 7.1.4-200.fc44 while `updates` has
# moved on to 7.1.4-202.fc44 and `updates-archive` never picked -200 up. When
# that happens `dnf5 install kernel-devel-<version>` dies with "No match for
# argument", and akmods becomes uninstallable too because its
# `(kernel-devel-matched if kernel-core)` rich dependency can only be satisfied
# by the installed kernel's version. Koji keeps every build forever, so fall
# back to fetching the rpms straight from there.

# install_kernel_devel <kernel-version>
#   e.g. install_kernel_devel 7.1.4-200.fc44.x86_64
install_kernel_devel() {
  local kv="$1"
  local pkgs=("kernel-devel-${kv}" "kernel-devel-matched-${kv}")

  if dnf5 install -y "${pkgs[@]}"; then
    return 0
  fi

  echo "kernel-devel ${kv} is not in the enabled repos; falling back to Koji"

  # 7.1.4-200.fc44.x86_64 -> version 7.1.4, release 200.fc44, arch x86_64
  local arch="${kv##*.}"
  local nvr="${kv%.*}"
  local version="${nvr%%-*}"
  local release="${nvr#*-}"
  local base="https://kojipkgs.fedoraproject.org/packages/kernel/${version}/${release}/${arch}"

  local dir
  dir="$(mktemp -d)"
  local rpms=()
  local pkg
  for pkg in kernel-devel kernel-devel-matched; do
    local rpm="${pkg}-${kv}.rpm"
    curl -fsSL -o "${dir}/${rpm}" "${base}/${rpm}"
    rpms+=("${dir}/${rpm}")
  done

  # Koji's unsigned build artifacts, hence --nogpgcheck.
  dnf5 install -y --nogpgcheck "${rpms[@]}"
  rm -rf "${dir}"
}
