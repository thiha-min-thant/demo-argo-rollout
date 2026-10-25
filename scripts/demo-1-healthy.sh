#!/usr/bin/env bash
# README §13 — healthy canary. Rolls the next canarybird version (v1 → v2 green by default).
# Weights step 10 → 30 → 60, then a manual gate. Watch the observer grid at http://localhost:8080.
#   scripts/demo-1-healthy.sh            start the canary and follow it to the manual gate
#   scripts/demo-1-healthy.sh promote    promote past the gate (→ 100 %, stable switched)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "${1:-}" == "promote" ]]; then
  step "Promoting past the manual gate"
  if have_rollouts_plugin; then kr promote demo -n demo
  else k patch rollout demo -n demo --type merge -p '{"status":{"pauseConditions":null}}' --subresource=status >/dev/null; fi
  k wait -n demo --for=jsonpath='{.status.phase}'=Healthy rollout/demo --timeout=300s
  info "phase:   $(rollout_phase)"
  info "weights: $(route_weights)   (canary back to 0)"
  info "stable:  VERSION=$(stable_env VERSION) COLOR=$(stable_env COLOR)"
  exit 0
fi

cur=$(stable_env VERSION); next=${1:-$(next_version)}
step "Demo 1 — canary ${cur:-?} → ${next} ($(color_for "${next}"))"
[[ "$(rollout_phase)" == "Healthy" ]] || warn "rollout is '$(rollout_phase)', expected Healthy before starting"
set_version "${next}"

step "Following the canary (Ctrl-C stops watching; the rollout keeps going)"
last=""
while true; do
  phase=$(rollout_phase); w=$(route_weights)
  line="phase=${phase}  weights=[${w}]  $(analysis_summary | tr '\n' ' ')"
  [[ "${line}" != "${last}" ]] && { echo "$(date '+%H:%M:%S')  ${line}"; last="${line}"; }
  case "${phase}" in
    Degraded) warn "rollout degraded: $(rollout_message)"; exit 1 ;;
    Paused)
      if [[ "${w}" == *"demo-canary=60"* ]]; then
        echo; info "Manual gate reached at 60 %. The grid should show ~60 % $(color_for "${next}")."
        info "Promote with:  scripts/demo-1-healthy.sh promote"
        exit 0
      fi ;;
  esac
  sleep 5
done
