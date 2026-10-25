#!/usr/bin/env bash
# Build the whole lab (README §4–§12) on a fresh kind cluster. Idempotent:
# `helm upgrade --install` + `kubectl apply`, so re-running converges instead of failing.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for t in docker kind kubectl helm jq curl; do need "$t"; done
docker info >/dev/null 2>&1 || die "docker daemon not running"

step "1/8 kind cluster '${CLUSTER_NAME}' (${K8S_NODE_IMAGE%%@*})"
if cluster_exists; then
  info "cluster exists, reusing"
else
  kind create cluster --config "${MANIFESTS}/kind-config.yaml"
fi
k get nodes -o wide

step "2/8 Gateway API CRDs ${GATEWAY_API_VERSION} (standard channel)"
k apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
k wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io --timeout=60s

step "3/8 Istio ${ISTIO_VERSION} ambient (base, istiod, cni, ztunnel)"
helm repo add istio "${ISTIO_CHART_REPO}" >/dev/null 2>&1 || true
helm repo update istio >/dev/null
h upgrade --install istio-base istio/base -n istio-system --create-namespace --version "${ISTIO_VERSION}" --wait
h upgrade --install istiod     istio/istiod  -n istio-system --version "${ISTIO_VERSION}" --set profile=ambient --wait
h upgrade --install istio-cni  istio/cni     -n istio-system --version "${ISTIO_VERSION}" --set profile=ambient --wait
h upgrade --install ztunnel    istio/ztunnel -n istio-system --version "${ISTIO_VERSION}" --wait
k get pods -n istio-system

step "4/8 Gateway (istio-ingress/demo-gateway)"
k apply -f "${MANIFESTS}/gateway.yaml"
k wait -n istio-ingress --for=condition=Programmed gateway/demo-gateway --timeout=180s
k rollout status -n istio-ingress deploy/demo-gateway-istio --timeout=180s

step "5/8 kube-prometheus-stack ${KPS_CHART_VERSION}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
h upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace --version "${KPS_CHART_VERSION}" \
  -f "${MANIFESTS}/kps-values.yaml" --wait --timeout 10m
k apply -f "${MANIFESTS}/istio-envoy-podmonitor.yaml"

step "6/8 Argo Rollouts chart ${ARGO_ROLLOUTS_CHART_VERSION} (app ${ARGO_ROLLOUTS_VERSION}) + Gateway API plugin ${GWAPI_PLUGIN_VERSION}"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
h upgrade --install argo-rollouts argo/argo-rollouts \
  -n argo-rollouts --create-namespace --version "${ARGO_ROLLOUTS_CHART_VERSION}" \
  -f "${MANIFESTS}/argo-rollouts-values.yaml" --wait
if k logs -n argo-rollouts deploy/argo-rollouts --all-containers 2>/dev/null | grep -qi 'argoproj-labs/gatewayAPI'; then
  info "plugin argoproj-labs/gatewayAPI loaded"
else
  warn "no plugin log line yet; check: kubectl --context ${KUBE_CONTEXT} logs -n argo-rollouts deploy/argo-rollouts | grep -i plugin"
fi

step "7/8 demo namespace + plugin RBAC"
k apply -f "${MANIFESTS}/rollouts-gwapi-rbac.yaml"
info "can patch httproutes in demo:    $(k auth can-i patch httproutes.gateway.networking.k8s.io -n demo    --as=system:serviceaccount:argo-rollouts:argo-rollouts)"
info "can patch httproutes in default: $(k auth can-i patch httproutes.gateway.networking.k8s.io -n default --as=system:serviceaccount:argo-rollouts:argo-rollouts)"

step "8/8 canarybird: image, AnalysisTemplate, PodMonitor, Services, HTTPRoute, Rollout, observer"
if docker manifest inspect "${CANARYBIRD_IMAGE}" >/dev/null 2>&1; then
  info "${CANARYBIRD_IMAGE} is pullable from the registry"
else
  warn "${CANARYBIRD_IMAGE} is not pullable (tag not published yet) — building it locally and loading into kind"
  bash "${REPO_ROOT}/scripts/build-canarybird.sh"
fi
k apply -f "${MANIFESTS}/analysis-template.yaml"
k apply -f "${MANIFESTS}/canarybird-podmonitor.yaml"
k apply -f "${MANIFESTS}/demo-app.yaml"
k wait -n demo --for=jsonpath='{.status.phase}'=Healthy rollout/demo --timeout=300s
k wait -n demo --for=condition=Available deploy/canarybird-observer --timeout=180s
info "HTTPRoute weights: $(route_weights)"
k get httproute demo -n demo -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}'; echo
info "stable version: $(stable_env VERSION) ($(stable_env COLOR))"

step "Lab is up"
cat <<MSG
  Context:      ${KUBE_CONTEXT}
  UI:           scripts/port-forward.sh   → http://localhost:8080 canarybird observer (grid + Break-something)
                                            http://localhost:8081 same app via the Istio gateway
                                            http://localhost:9090 Prometheus, :3100 Rollouts dashboard
  Demo 1:       scripts/demo-1-healthy.sh  (v1 → v2, manual gate at 60 %; then `promote`)
  Demo 2:       scripts/demo-2-rollback.sh (next version + error-spike on it → automatic abort; then `undo`)
  Watch:        scripts/watch.sh
  Tear down:    scripts/cleanup.sh
MSG
