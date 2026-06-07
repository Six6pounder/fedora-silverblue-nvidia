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

# The CLI image's entrypoint is dumb-init, so the first arg must be the binary
# name (`bluebuild`), not the subcommand. Force the buildah build driver: the
# default detection reaches for docker (buildx) and fails on /var/run/docker.sock
# under podman; buildah is bundled in the CLI image and uses the storage we mount.
build_args=(bluebuild build --build-driver buildah)

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

  # Signing: BlueBuild signs by default (the recipe has a `signing` module and
  # cosign.pub is present), and ERRORS OUT if no key is available -- so when we
  # have no key we must explicitly pass --no-sign to push an unsigned image.
  if [[ -n "${COSIGN_PRIVATE_KEY:-}" ]]; then
    podman_args+=(-e COSIGN_PRIVATE_KEY)
  elif [[ -f "${SCRIPT_DIR}/cosign.key" ]]; then
    : # bluebuild auto-detects ./cosign.key from the mounted repo root
  else
    build_args+=(--no-sign)
    echo "WARNING: no cosign key (COSIGN_PRIVATE_KEY unset, no ./cosign.key) --" >&2
    echo "         pushing UNSIGNED with --no-sign. Rebase via" >&2
    echo "         ostree-unverified-registry: (not ostree-image-signed:)." >&2
  fi
fi

podman_args+=("${CLI_IMAGE}")

echo ">> podman ${podman_args[*]} ${build_args[*]} ${RECIPE}"
exec podman "${podman_args[@]}" "${build_args[@]}" "${RECIPE}"
