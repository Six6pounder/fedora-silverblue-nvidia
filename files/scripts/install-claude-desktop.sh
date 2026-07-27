#!/usr/bin/env bash

# Install Anthropic's Claude Desktop app into the image.
#
# Anthropic only ships Linux builds as a .deb through their own apt repository
# (https://code.claude.com/docs/en/desktop-linux) -- there is no RPM, Flatpak or
# tarball, and the docs explicitly list Fedora/RHEL as unsupported. The payload
# itself is a self-contained Electron app under /usr/lib/claude-desktop plus a
# symlink, a .desktop entry and hicolor icons, none of which is Debian-specific,
# so we unpack the .deb straight into the image rather than repackaging it.
#
# All of the .deb's Depends are satisfied by packages already in this image
# (libgtk-3, libnotify, libnss3, libatspi, libdrm, libgbm, libxcb-dri3,
# libsecret, libXtst, libuuid, xdg-utils, xdg-desktop-portal + a backend); the
# ldd check at the end fails the build if that ever stops being true. The
# Recommends that matter (appindicator tray, and qemu/ovmf/virtiofsd for the
# Cowork VM sandbox) are installed via the dnf module in the recipe.
#
# Unlike build-xone.sh / build-virtualbox.sh we deliberately do NOT pin a
# version: this is an application, not a kernel module, so it should track
# upstream on every rebuild the same way the dnf-installed packages do.
#
# The download is verified the way apt would: the InRelease index is checked
# against Anthropic's signing key, the Packages index against the hash in
# InRelease, and the .deb against the hash in Packages.

set -euo pipefail

REPO_BASE="https://downloads.claude.ai/claude-desktop"
DIST_BASE="${REPO_BASE}/apt/stable"
# Fingerprint published at https://code.claude.com/docs/en/desktop-linux
KEY_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

# Debian architecture name, derived from the build container's arch (the images
# are built for x86_64 today, but keep this honest rather than hardcoded).
case "$(uname -m)" in
  x86_64)  DEB_ARCH="amd64" ;;
  aarch64) DEB_ARCH="arm64" ;;
  *) echo "Claude Desktop: no upstream package for $(uname -m)" >&2; exit 1 ;;
esac

# gnupg2 verifies the repository signature; bsdtar reads both the outer `ar`
# container of the .deb and the inner data.tar.xz. Both stay in the image, which
# is fine -- they are small and generally useful.
dnf5 install -y gnupg2 bsdtar

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- Verify the repository index -------------------------------------------

export GNUPGHOME="${WORK}/gnupg"
install -d -m 700 "${GNUPGHOME}"

curl -fsSL "${REPO_BASE}/key.asc" -o "${WORK}/key.asc"
gpg --quiet --import "${WORK}/key.asc"

# Fail loudly if the key served to us is not the one Anthropic documents.
if ! gpg --list-keys --with-colons \
  | awk -F: '/^fpr:/ { print $10 }' \
  | grep -qx "${KEY_FINGERPRINT}"; then
  echo "Claude Desktop: signing key fingerprint mismatch" >&2
  gpg --list-keys --with-colons | awk -F: '/^fpr:/ { print $10 }' >&2
  exit 1
fi

# InRelease is clearsigned: --decrypt both verifies it and writes the payload.
curl -fsSL "${DIST_BASE}/dists/stable/InRelease" -o "${WORK}/InRelease"
gpg --quiet --output "${WORK}/Release" --decrypt "${WORK}/InRelease"

# Pull the expected checksum of our architecture's Packages file out of the
# SHA256 block (the file also carries MD5Sum/SHA1/SHA512 blocks; the awk range
# ends at the next unindented field name).
PACKAGES_PATH="main/binary-${DEB_ARCH}/Packages"
PACKAGES_SHA256="$(awk -v path="${PACKAGES_PATH}" '
  /^SHA256:/ { in_block = 1; next }
  /^[^ ]/    { in_block = 0 }
  in_block && $3 == path { print $1; exit }
' "${WORK}/Release")"

if [[ -z "${PACKAGES_SHA256}" ]]; then
  echo "Claude Desktop: no SHA256 entry for ${PACKAGES_PATH} in Release" >&2
  exit 1
fi

curl -fsSL "${DIST_BASE}/dists/stable/${PACKAGES_PATH}" -o "${WORK}/Packages"
echo "${PACKAGES_SHA256}  ${WORK}/Packages" | sha256sum --check --status

# --- Pick and fetch the newest package --------------------------------------

# Packages is a series of blank-line-separated stanzas; emit one
# "version|filename|sha256" line per claude-desktop stanza and take the highest
# version by `sort -V`.
NEWEST="$(awk -v RS='' -v arch="${DEB_ARCH}" '
  {
    pkg = ""; ver = ""; file = ""; sha = ""; a = ""
    n = split($0, lines, "\n")
    for (i = 1; i <= n; i++) {
      split(lines[i], kv, ": ")
      if (kv[1] == "Package")      pkg  = kv[2]
      else if (kv[1] == "Version") ver  = kv[2]
      else if (kv[1] == "Architecture") a = kv[2]
      else if (kv[1] == "Filename") file = kv[2]
      else if (kv[1] == "SHA256")  sha  = kv[2]
    }
    if (pkg == "claude-desktop" && a == arch && ver && file && sha)
      print ver "|" file "|" sha
  }
' "${WORK}/Packages" | sort -V | tail -n 1)"

if [[ -z "${NEWEST}" ]]; then
  echo "Claude Desktop: no claude-desktop package for ${DEB_ARCH} in the index" >&2
  exit 1
fi

IFS='|' read -r DEB_VERSION DEB_FILENAME DEB_SHA256 <<< "${NEWEST}"
echo "Installing Claude Desktop ${DEB_VERSION} (${DEB_ARCH})"

curl -fsSL "${DIST_BASE}/${DEB_FILENAME}" -o "${WORK}/claude-desktop.deb"
echo "${DEB_SHA256}  ${WORK}/claude-desktop.deb" | sha256sum --check --status

# --- Unpack into the image ---------------------------------------------------

# Stage first so we control exactly what lands in /usr: the .deb ships only
# ./usr today, but staging means a future stanza that adds ./etc or ./opt shows
# up as a build-time surprise instead of silently modifying the image.
STAGE="${WORK}/stage"
install -d "${STAGE}"
bsdtar -xOf "${WORK}/claude-desktop.deb" data.tar.xz \
  | bsdtar -xpf - -C "${STAGE}" ./usr

# Debian packaging metadata that means nothing on Fedora. The copyright file is
# kept: it carries the app's license text.
rm -rf "${STAGE}/usr/share/lintian"

cp -a "${STAGE}/usr/." /usr/

# Chromium's setuid sandbox helper. dpkg would do this in a postinst; without it
# Electron refuses to start with "The SUID sandbox helper binary was found, but
# is not configured correctly".
chown root:root /usr/lib/claude-desktop/chrome-sandbox
chmod 4755 /usr/lib/claude-desktop/chrome-sandbox

# --- Verify what we installed ------------------------------------------------

test -x /usr/bin/claude-desktop
test -u /usr/lib/claude-desktop/chrome-sandbox
test -f /usr/share/applications/com.anthropic.Claude.desktop
test -f /usr/share/icons/hicolor/256x256/apps/claude-desktop.png

# The .deb's dependencies are Debian package names, so nothing has checked them
# against this image. Resolve the Electron binary's actual shared libraries and
# fail the build if any are missing -- that is the signal that a future Fedora
# release dropped or renamed something the app needs.
if ldd /usr/lib/claude-desktop/claude-desktop | grep 'not found'; then
  echo "Claude Desktop: unresolved shared libraries (see above)" >&2
  exit 1
fi

echo "Claude Desktop ${DEB_VERSION} installed successfully"
