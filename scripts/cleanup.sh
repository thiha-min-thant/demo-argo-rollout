#!/usr/bin/env bash
# README §18 — delete the lab cluster only (never another kind cluster).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if cluster_exists; then
  kind delete cluster --name "${CLUSTER_NAME}"
else
  info "kind cluster '${CLUSTER_NAME}' does not exist; nothing to do"
fi
