#!/usr/bin/env bash

# Remove the local artifacts left behind by build-local.sh:
#   - the generated ./Containerfile
#   - the BlueBuild CLI temp script dirs (./.bluebuild-scripts_*)
#   - the isolated container-storage cache (./.build-cache/), which holds the
#     pulled base image plus the built image and can be several GB.
#
# Usage:
#   ./clean-build.sh               # remove everything, incl. the layer cache
#   ./clean-build.sh --keep-cache  # only temp leftovers; keep .build-cache/
#                                  # so the next build doesn't re-pull the base

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "${SCRIPT_DIR}"

KEEP_CACHE=0
case "${1:-}" in
  --keep-cache) KEEP_CACHE=1 ;;
  -h|--help)    sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "")           ;;
  *) echo "Unknown argument: $1" >&2; exit 1 ;;
esac

# Refuse to run mid-build: deleting the storage out from under a running build
# would corrupt it.
if podman ps --format '{{.Image}}' 2>/dev/null | grep -q 'blue-build/cli'; then
  echo "ERROR: a BlueBuild CLI container is still running -- let the build finish" >&2
  echo "       (or stop it) before cleaning." >&2
  exit 1
fi

removed_any=0

# Generated Containerfile.
if [[ -e Containerfile ]]; then
  echo "Removing ./Containerfile"
  rm -f Containerfile
  removed_any=1
fi

# BlueBuild CLI temp script dirs.
for d in .bluebuild-scripts_*; do
  [[ -e "$d" ]] || continue
  echo "Removing ./$d ($(du -sh "$d" 2>/dev/null | cut -f1))"
  rm -rf "$d"
  removed_any=1
done

# Isolated layer-cache storage (subuid-owned -> must delete inside the user
# namespace, otherwise plain rm hits "permission denied").
if [[ -d .build-cache ]]; then
  if [[ "${KEEP_CACHE}" -eq 1 ]]; then
    echo "Keeping ./.build-cache/ ($(podman unshare du -sh .build-cache 2>/dev/null | cut -f1))"
  else
    echo "Removing ./.build-cache/ ($(podman unshare du -sh .build-cache 2>/dev/null | cut -f1))"
    podman unshare rm -rf .build-cache
    removed_any=1
  fi
fi

if [[ "${removed_any}" -eq 0 ]]; then
  echo "Nothing to clean."
else
  echo "Done."
fi
