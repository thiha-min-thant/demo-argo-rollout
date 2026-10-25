#!/usr/bin/env bash
# Build ghcr.io/thiha-min-thant/canarybird:dev from the local checkout and load it into the lab
# cluster. Needed until the tag exists on ghcr.io (release.yml publishes semver + latest only).
#   scripts/build-canarybird.sh          build + kind load
#   scripts/build-canarybird.sh --push   also push to ghcr.io (needs `docker login ghcr.io`)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker; need kind
[[ -f "${CANARYBIRD_SRC}/Dockerfile" ]] || die "canarybird source not found at ${CANARYBIRD_SRC} (set CANARYBIRD_SRC)"

step "Building ${CANARYBIRD_IMAGE} from ${CANARYBIRD_SRC} ($(uname -m))"
docker build --build-arg VERSION=dev -t "${CANARYBIRD_IMAGE}" "${CANARYBIRD_SRC}"
docker image inspect "${CANARYBIRD_IMAGE}" --format '    image id {{.Id}}  size {{.Size}} bytes  arch {{.Architecture}}'

if cluster_exists; then
  step "Loading into kind cluster ${CLUSTER_NAME}"
  kind load docker-image "${CANARYBIRD_IMAGE}" --name "${CLUSTER_NAME}"
else
  warn "kind cluster ${CLUSTER_NAME} not found; skipping kind load (setup.sh will call this again)"
fi

if [[ "${1:-}" == "--push" ]]; then
  step "Pushing ${CANARYBIRD_IMAGE}"
  docker push "${CANARYBIRD_IMAGE}"
fi
