#!/usr/bin/env bash

# Build this BlueBuild image locally with the BlueBuild CLI (run as a podman
# container, so nothing needs to be installed on the atomic host). Handy for
# validating recipe changes -- e.g. that the xone kernel module actually
# compiles against the image's kernel -- in a few minutes instead of waiting on
# the GitHub Actions build.
#
# Usage:
#   ./build-local.sh              # build only (validate, image kept in local cache)
#   ./build-local.sh --push       # build AND push to ghcr.io/<owner>/<name>
#   ./build-local.sh -r recipes/other.yml [--push]
#
# Pushing requires being logged in to the registry first:
#   podman login ghcr.io          # PAT needs the write:packages scope
# Signing (optional) reuses the CI cosign key if you export it:
#   export COSIGN_PRIVATE_KEY="$(cat cosign.key)"
# Without it the pushed image is UNSIGNED -- rebase via ostree-unverified-registry:.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RECIPE="recipes/recipe.yml"
PUSH=0
CLI_IMAGE="ghcr.io/blue-build/cli:latest"

usage() {
  sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)        PUSH=1; shift ;;
    -r|--recipe)   RECIPE="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

# Isolated container storage so we get layer caching across runs (the base image
# is several GB) WITHOUT mounting -- and risking lock corruption on -- the host's
# live podman storage. Gitignored.
CACHE_DIR="${SCRIPT_DIR}/.build-cache/storage"
mkdir -p "${CACHE_DIR}"

podman_args=(
  run --rm --privileged
  --security-opt label=disable
  -v "${SCRIPT_DIR}":/build -w /build
  -v "${CACHE_DIR}":/var/lib/containers/storage
)

build_args=(build)

if [[ "${PUSH}" -eq 1 ]]; then
  build_args+=(--push)

  # Reuse the host's `podman login` credentials inside the CLI container.
  auth_file="${REGISTRY_AUTH_FILE:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json}"
  if [[ ! -f "${auth_file}" ]]; then
    echo "ERROR: --push needs registry credentials, but no auth file was found at:" >&2
    echo "       ${auth_file}" >&2
    echo "       Log in first:  podman login ghcr.io   (PAT needs write:packages)" >&2
    exit 1
  fi
  podman_args+=(
    -v "${auth_file}":/run/containers/auth.json:ro
    -e REGISTRY_AUTH_FILE=/run/containers/auth.json
  )

  # Pass the cosign signing key through if available, else push unsigned.
  if [[ -n "${COSIGN_PRIVATE_KEY:-}" ]]; then
    podman_args+=(-e COSIGN_PRIVATE_KEY)
  else
    echo "WARNING: COSIGN_PRIVATE_KEY not set -- the pushed image will be UNSIGNED." >&2
    echo "         Rebase to it with ostree-unverified-registry: (not ostree-image-signed:)." >&2
  fi
fi

podman_args+=("${CLI_IMAGE}")

echo ">> podman ${podman_args[*]} ${build_args[*]} ${RECIPE}"
exec podman "${podman_args[@]}" "${build_args[@]}" "${RECIPE}"
