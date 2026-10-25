#!/usr/bin/env bash
# README §14 — bad canary. Rolls the next version, then breaks ONLY that version at runtime through
# canarybird's /control (no new image). The gates fail → AnalysisRun Failed → rollout aborted →
# HTTPRoute weights snap back to stable=100/canary=0 → canary ReplicaSet scaled down.
#   scripts/demo-2-rollback.sh [scenario]   scenario: error-spike (default) | slow-burn | flaky | not-ready
#   scripts/demo-2-rollback.sh undo         revert the desired state to the stable version
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need curl; need jq

if [[ "${1:-}" == "undo" ]]; then
  step "Reverting desired state to the stable version"
  sv=$(stable_env VERSION); sc=$(stable_env COLOR)
  [[ -n "${sv}" ]] || die "could not read the stable ReplicaSet"
  set_version "${sv}" "${sc}"
  k wait -n demo --for=jsonpath='{.status.phase}'=Healthy rollout/demo --timeout=300s
  info "phase: $(rollout_phase)   weights: $(route_weights)"
  exit 0
fi

scenario=${1:-error-spike}
cur=$(stable_env VERSION); next=$(next_version)
step "Demo 2 — canary ${cur:-?} → ${next} ($(color_for "${next}")), then '${scenario}' on ${next} only"
[[ "$(rollout_phase)" == "Healthy" ]] || warn "rollout is '$(rollout_phase)', expected Healthy before starting"
set_version "${next}"

step "Waiting for the first ${next} pod to be ready"
for _ in $(seq 1 60); do
  ready=$(k get pods -n demo -l app=demo -o json | jq -r --arg v "${next}" \
    '[.items[] | select(.spec.containers[0].env[] | select(.name=="VERSION" and .value==$v)) | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')
  [[ "${ready:-0}" -ge 1 ]] && break; sleep 3
done
[[ "${ready:-0}" -ge 1 ]] || die "no ready ${next} pod after 3 minutes"
info "weights now: $(route_weights)"

step "Breaking ${next}: PUT /control scenario=${scenario} target_version=${next} (fan-out via demo-headless)"
canarybird_control "scenario=${scenario}&target_version=${next}"
info "Stable pods are untouched — the grid shows red slashes only on $(color_for "${next}") squares."

step "Waiting for the AnalysisRun to fail and the rollout to abort (~1–2 min)"
last=""
while true; do
  phase=$(rollout_phase); w=$(route_weights)
  line="phase=${phase}  weights=[${w}]  $(analysis_summary | tr '\n' ' ')"
  [[ "${line}" != "${last}" ]] && { echo "$(date '+%H:%M:%S')  ${line}"; last="${line}"; }
  if [[ "${phase}" == "Degraded" ]]; then
    echo; info "Aborted: $(rollout_message)"
    info "weights now: $(route_weights)"
    echo; info "Evidence (latest AnalysisRun metric results):"
    ar=$(k get analysisrun -n demo --sort-by=.metadata.creationTimestamp -o name | tail -1)
    k get -n demo "${ar}" -o jsonpath='{range .status.metricResults[*]}  {.name}: phase={.phase} failed={.failed} successful={.successful} last={.measurements[-1].value}{"\n"}{end}'
    echo; info "Recover with:  scripts/demo-2-rollback.sh undo   (or: kubectl argo rollouts undo demo -n demo)"
    exit 0
  fi
  if [[ "${phase}" == "Healthy" && "${w}" == *"demo-canary=0"* && "${last}" == *"Progressing"* ]]; then
    warn "rollout completed instead of aborting — check Prometheus has gateway + canarybird metrics (README §17)"; exit 1
  fi
  sleep 5
done
