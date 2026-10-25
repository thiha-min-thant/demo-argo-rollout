#!/usr/bin/env bash
# Port-forwards for the lab. Ctrl-C stops all of them.
#   :8080 → canarybird observer UI (grid, Traffic + Break-something panels)   http://localhost:8080
#   :8081 → the rollout pods via the Istio gateway (what the loadgen hits)     http://localhost:8081/api/version
#   :9090 → Prometheus                                                        http://localhost:9090
#   :3100 → Argo Rollouts dashboard                                           http://localhost:3100
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
pids=()
trap 'kill "${pids[@]}" 2>/dev/null; exit 0' INT TERM
k -n demo          port-forward svc/canarybird-observer 8080:80 >/dev/null & pids+=($!)
k -n istio-ingress port-forward svc/demo-gateway-istio 8081:80 >/dev/null & pids+=($!)
k -n monitoring    port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null & pids+=($!)
k -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100 >/dev/null & pids+=($!)
info "observer UI  http://localhost:8080"
info "via gateway  http://localhost:8081/api/version   (repeat to see the split)"
info "prometheus   http://localhost:9090   try: sum by (target_version) (rate(canarybird_loadgen_requests_total[1m]))"
info "dashboard    http://localhost:3100"
info "Ctrl-C to stop"
wait
