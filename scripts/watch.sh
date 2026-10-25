#!/usr/bin/env bash
# Live view: rollout phase, HTTPRoute weights, AnalysisRuns, pods by VERSION. Ctrl-C to stop.
# With the kubectl plugin installed, `kubectl argo rollouts get rollout demo -n demo --watch` is richer.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
while true; do
  printf '\033[2J\033[H'
  echo "context: ${KUBE_CONTEXT}    $(date '+%H:%M:%S')"
  echo
  echo "Rollout:     $(rollout_phase)   $(rollout_message)"
  echo "Desired:     VERSION=$(desired_env VERSION) COLOR=$(desired_env COLOR)    Stable: VERSION=$(stable_env VERSION) COLOR=$(stable_env COLOR)"
  echo "Weights:     $(route_weights)"
  echo "Route label: $(k get httproute demo -n demo -o jsonpath='{.metadata.labels.rollouts\.argoproj\.io/gatewayapi-canary}' 2>/dev/null)"
  echo
  echo "AnalysisRuns:"; analysis_summary | sed 's/^/  /'
  echo
  k get pods -n demo -l app=demo -o custom-columns='POD:.metadata.name,VERSION:.spec.containers[0].env[?(@.name=="VERSION")].value,COLOR:.spec.containers[0].env[?(@.name=="COLOR")].value,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' 2>/dev/null
  sleep 3
done
