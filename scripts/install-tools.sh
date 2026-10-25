#!/usr/bin/env bash
# Install / verify the CLIs the lab needs. Idempotent; safe to re-run.
#   kubectl-argo-rollouts (checksum-verified against the release's checksums file)
#   istioctl (optional, for `analyze` / `ztunnel-config`)
# Expects docker, kind, kubectl, helm, jq, curl to be present already (brew install kind kubectl helm jq).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OS=$(uname | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
SUDO=""; [[ -w "${BIN_DIR}" ]] || SUDO=sudo
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

step "Checking base tooling"
for t in docker kind kubectl helm jq curl; do need "$t"; done
info "docker  $(docker version --format '{{.Client.Version}}' 2>/dev/null || echo '?')"
info "kind    $(kind version | awk '{print $2}')   (want ${KIND_VERSION})"
info "kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion)   (cluster will be ${K8S_VERSION}; keep within ±1 minor)"
info "helm    $(helm version --short)"
[[ "$(kind version | awk '{print $2}')" == "${KIND_VERSION}" ]] || warn "kind is not ${KIND_VERSION}; node image digests in versions.env come from that release"

step "kubectl-argo-rollouts ${ARGO_ROLLOUTS_VERSION}"
if have_rollouts_plugin && kubectl argo rollouts version 2>/dev/null | grep -q "${ARGO_ROLLOUTS_VERSION}"; then
  info "already installed: $(kubectl argo rollouts version --short 2>/dev/null | head -1)"
else
  BASE="https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}"
  ASSET="kubectl-argo-rollouts-${OS}-${ARCH}"
  curl -fsSL -o "${WORK}/${ASSET}" "${BASE}/${ASSET}"
  curl -fsSL -o "${WORK}/checksums.txt" "${BASE}/argo-rollouts-checksums.txt"
  WANT=$(awk -v a="${ASSET}" '$2==a{print $1}' "${WORK}/checksums.txt")
  GOT=$(sha256 "${WORK}/${ASSET}")
  [[ -n "${WANT}" && "${WANT}" == "${GOT}" ]] || die "checksum mismatch for ${ASSET}: want ${WANT:-<none>} got ${GOT}"
  info "sha256 ok: ${GOT}"
  chmod +x "${WORK}/${ASSET}"
  ${SUDO} mv "${WORK}/${ASSET}" "${BIN_DIR}/kubectl-argo-rollouts"
  info "installed: $(kubectl argo rollouts version --short 2>/dev/null | head -1)"
fi

step "istioctl ${ISTIO_VERSION} (optional)"
if command -v istioctl >/dev/null && istioctl version --remote=false 2>/dev/null | grep -q "${ISTIO_VERSION}"; then
  info "already installed: $(istioctl version --remote=false)"
else
  ( cd "${WORK}" && curl -fsSL https://istio.io/downloadIstio | ISTIO_VERSION="${ISTIO_VERSION}" sh - >/dev/null )
  ${SUDO} mv "${WORK}/istio-${ISTIO_VERSION}/bin/istioctl" "${BIN_DIR}/istioctl"
  info "installed: $(istioctl version --remote=false)"
fi

step "Done"
