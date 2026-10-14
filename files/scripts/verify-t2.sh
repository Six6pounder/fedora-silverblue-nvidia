#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "T2 verification failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

mapfile -t kernels < <(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
[[ ${#kernels[@]} -eq 1 && "${kernels[0]}" == *.t2.fc44.x86_64 ]] || {
  fail "Expected exactly one Fedora 44 T2 kernel; found: ${kernels[*]}"
}
kv="${kernels[0]}"
echo "Checking T2 kernel packages: ${kv}"
for package in kernel kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched; do
  installed="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' "${package}")"
  [[ "${installed}" == "${kv}" ]] || fail "${package}: expected ${kv}, found ${installed}"
done
echo 'Checking T2 and external kernel modules'
for module in t2bce_dma t2bce_core t2bce_vhci t2bce_audio brcmfmac hci_bcm4377 hfsplus loop vboxdrv xone-gip xone-dongle; do
  modinfo -k "${kv}" "${module}" >/dev/null || fail "Missing module ${module} for ${kv}"
done
rpm -q t2linux-config t2linux-audio t2fanrd >/dev/null
image="/usr/lib/modules/${kv}/initramfs.img"
[[ -s "${image}" ]] || fail "Missing or empty initramfs: ${image}"
[[ -s "/usr/lib/modules/${kv}/vmlinuz" ]] || fail "Missing kernel image for ${kv}"
echo "Checking initramfs drivers: ${image}"
listing="$(lsinitrd "${image}")"
for module in t2bce_dma t2bce_core t2bce_vhci hid_apple; do
  # Module names normalize '-' to '_', but archive filenames do not:
  # hid_apple is stored as hid-apple.ko, possibly with a compression suffix.
  filename="$(modinfo -k "${kv}" -F filename "${module}")"
  [[ "${filename}" == '(builtin)' ]] && continue
  basename="${filename##*/}"
  basename="${basename%.xz}"
  basename="${basename%.zst}"
  basename="${basename%.gz}"
  [[ -n "${basename}" ]] || fail "Cannot resolve filename for ${module}"
  grep -F -- "${basename}" <<<"${listing}" >/dev/null || \
    fail "Initramfs does not contain ${module} (${basename})"
done
[[ -x /usr/bin/sixpounder-t2-firmware ]] || fail 'Firmware command is not executable'
[[ -x /usr/libexec/sixpounder-t2/rename-firmware ]] || fail 'Firmware renamer is not executable'
echo "Verified T2 kernel, external modules and initramfs: ${kv}"
