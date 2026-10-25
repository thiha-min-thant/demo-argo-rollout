#!/usr/bin/env bash
# Shared helpers. Source from the other scripts; do not run directly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="${REPO_ROOT}/manifests"
# shellcheck source=../versions.env
source "${REPO_ROOT}/versions.env"

# Every kubectl/helm call is pinned to the lab cluster's context so an existing
# kubeconfig context (e.g. a real cluster) is never touched by accident.
k()  { kubectl --context "${KUBE_CONTEXT}" "$@"; }
h()  { helm --kube-context "${KUBE_CONTEXT}" "$@"; }
kr() { kubectl --context "${KUBE_CONTEXT}" argo rollouts "$@"; }

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31merror: %s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 (see scripts/install-tools.sh)"; }

have_rollouts_plugin() { kubectl argo rollouts version >/dev/null 2>&1; }
cluster_exists() { kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; }

# ---- rollout state -------------------------------------------------------------------------
route_weights() {
  k get httproute demo -n demo \
    -o jsonpath='{range .spec.rules[0].backendRefs[*]}{.name}={.weight} {end}' 2>/dev/null || true
}
rollout_phase()   { k get rollout demo -n demo -o jsonpath='{.status.phase}'   2>/dev/null || true; }
rollout_message() { k get rollout demo -n demo -o jsonpath='{.status.message}' 2>/dev/null || true; }
analysis_summary() {
  k get analysisrun -n demo --sort-by=.metadata.creationTimestamp \
    -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase}{"\n"}{end}' 2>/dev/null | tail -2 || true
}

# ---- canarybird: a "version" is the VERSION/COLOR env on the canarybird container ----------
ENV_PATH='.spec.template.spec.containers[?(@.name=="canarybird")].env[?(@.name=="%s")].value'
desired_env() { k get rollout demo -n demo -o jsonpath="{$(printf "${ENV_PATH}" "$1")}" 2>/dev/null || true; }
stable_env() {
  local hash; hash=$(k get rollout demo -n demo -o jsonpath='{.status.stableRS}' 2>/dev/null)
  [[ -n "${hash}" ]] || return 0
  k get rs -n demo -l "rollouts-pod-template-hash=${hash}" -o jsonpath="{.items[0]$(printf "${ENV_PATH}" "$1")}" 2>/dev/null || true
}
# v1→blue, v2→green, v3→purple, v4→orange, v5→yellow, v6→pink, v7→teal, then wraps
color_for() {
  local n=${1#v}; local palette=(blue green purple orange yellow pink teal)
  echo "${palette[$(( (n - 1) % ${#palette[@]} ))]}"
}
next_version() { local cur; cur=$(stable_env VERSION); cur=${cur:-v0}; echo "v$(( ${cur#v} + 1 ))"; }

# set_version vN [colour] — patches VERSION+COLOR on the Rollout template → new ReplicaSet → canary
set_version() {
  local v=$1 c=${2:-$(color_for "$1")}
  k patch rollout demo -n demo --type json -p "$(cat <<JSON
[
 {"op":"replace","path":"/spec/template/spec/containers/0/env/0","value":{"name":"VERSION","value":"${v}"}},
 {"op":"replace","path":"/spec/template/spec/containers/0/env/1","value":{"name":"COLOR","value":"${c}"}}
]
JSON
)" >/dev/null
  info "desired: VERSION=${v} COLOR=${c}"
}

# canarybird_control 'scenario=error-spike&target_version=v2' — PUT /control on the observer,
# which fans out to every rollout pod via demo-headless; prints which pods applied it.
canarybird_control() {
  local form=$1 port=${CB_LOCAL_PORT:-18080} pf
  k -n demo port-forward svc/canarybird-observer "${port}:80" >/dev/null 2>&1 & pf=$!
  trap 'kill ${pf} 2>/dev/null || true' RETURN
  for _ in $(seq 1 20); do curl -fs -o /dev/null "http://localhost:${port}/healthz" 2>/dev/null && break; sleep 0.5; done
  curl -fsS -X PUT -H 'Accept: application/json' -d "${form}" "http://localhost:${port}/control" \
    | jq -r '"applied to \(.applied) pod(s): " + ([.results[] | select(.applied) | "\(.pod) (\(.version))"] | join(", "))'
}
