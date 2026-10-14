#!/usr/bin/env bash
# Image build only: replace the stock kernel before any external module builds.
set -euo pipefail
if [[ ! -f /run/.containerenv && ! -f /.dockerenv ]] && \
   ! systemd-detect-virt --container --quiet; then
  echo 'install-t2.sh must run inside the image build container, never on the host' >&2
  exit 1
fi
source /etc/os-release
[[ "${ID}" == fedora && "${VERSION_ID}" == 44 && "$(rpm --eval '%{_arch}')" == x86_64 ]] || {
  echo 'T2 images require Fedora 44 x86_64' >&2
  exit 1
}

T2_REPO='copr:copr.fedorainfracloud.org:sharpenedblade:t2linux'
kv="$(dnf5 -q repoquery --available --arch=x86_64 --repo="${T2_REPO}" --latest-limit=1 \
  --queryformat '%{version}-%{release}.%{arch}' kernel-core)"
[[ "${kv}" == *.t2.fc44.x86_64 && "${kv}" != *$'\n'* ]] || {
  echo "Invalid or unavailable COPR T2 kernel: ${kv}" >&2
  exit 1
}

# rpm-ostree images must contain exactly one kernel. Erase only the kernel
# family, without dnf autoremove removing desktop packages that require it.
mapfile -t old_kernels < <(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
mapfile -t old_packages < <(rpm -qa --qf '%{NAME}\n' | \
  sed -n '/^kernel\(-core\|-modules\(-core\|-extra\|-extra-matched\)\?\|-devel\(-matched\)\?\)\?$/p' | sort -u)
[[ ${#old_packages[@]} -gt 0 ]] || { echo 'No base kernel found' >&2; exit 1; }
rpm -e --nodeps "${old_packages[@]}"
for old in "${old_kernels[@]}"; do
  [[ "${old}" =~ ^[0-9][a-zA-Z0-9._+-]+$ ]] || exit 1
  rm -rf "/usr/lib/modules/${old}"
done

kernel_packages=(kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched)
exact_packages=()
for package in "${kernel_packages[@]}"; do
  exact_packages+=("${package}-${kv}")
done
# Exact .t2 NVRs can only come from COPR; keep Fedora repos available for deps.
dnf5 install -y --setopt=install_weak_deps=False "${exact_packages[@]}"
dnf5 install -y --setopt=install_weak_deps=False \
  t2linux-release t2linux-config t2linux-audio t2fanrd \
  python3 curl dmg2img util-linux kmod sudo policycoreutils systemd-udev

# Vendor only the MIT firmware renamer, not upstream's mutable-system installer.
# Recovery downloader verifies Apple's signed chunklist and downloaded image.
install -d -m 755 /usr/libexec/sixpounder-t2
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
curl --fail --location --retry 3 -o "${work}/firmware.sh" \
  https://raw.githubusercontent.com/t2linux/wiki/f71483df460fb97d5c39edf3af03dfc5f6be9a7c/docs/tools/firmware.sh
echo "20bee898d75744e1b8d363762bd25fc1eadeb539d0ba363aef028a0bc260c41a  ${work}/firmware.sh" | sha256sum -c -
python3 - "${work}/firmware.sh" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
renamer, separator, _ = source.partition('\nset -euo pipefail\n')
assert separator and 'rename_firmware () {' in renamer
Path('/usr/libexec/sixpounder-t2/rename-firmware').write_text(
    renamer + '\nset -euo pipefail\nrename_firmware "$@"\n')
PY
curl --fail --location --retry 3 -o "${work}/fetch-macOS.py" \
  https://raw.githubusercontent.com/kholia/OSX-KVM/da4b23b5e92c5b939568700034367e8b7649fe90/fetch-macOS-v2.py
echo "39ac6d26bd265f5d32198062f515ad15ef93afb7a74e702be2b008090d5bd5f3  ${work}/fetch-macOS.py" | sha256sum -c -
install -m 644 "${work}/fetch-macOS.py" /usr/libexec/sixpounder-t2/fetch-macOS.py
chmod 755 /usr/libexec/sixpounder-t2/rename-firmware
depmod -a "${kv}"
