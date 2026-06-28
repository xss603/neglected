#!/usr/bin/env bash
set -euo pipefail

NAMESPACE=monitoring
RELEASE=kube-prom

echo "==> Creating namespace $NAMESPACE"
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing kube-prometheus-stack"
helm upgrade --install $RELEASE prometheus-community/kube-prometheus-stack \
  --namespace $NAMESPACE \
  --values values.yaml \
  --wait \
  --timeout 5m

echo "==> Applying dashboard ConfigMap"
# Inline the JSON into the ConfigMap
kubectl create configmap node-taint-monitor-dashboard \
  --namespace $NAMESPACE \
  --from-file=node-taint-monitor.json=dashboards/node-taint-monitor.json \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -

echo "==> Waiting for Grafana pod"
kubectl rollout status deployment/${RELEASE}-grafana -n $NAMESPACE --timeout=3m

echo ""
echo "==> Port-forward Grafana → http://localhost:3000  (admin / admin)"
echo "    kubectl port-forward svc/${RELEASE}-grafana 3000:80 -n $NAMESPACE"
