# CKA 2025 — Complete Answers

---

## Q1 — Kernel Parameters (sysctl)

Append the required parameters and apply without reboot.

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
vm.overcommit_memory = 1
vm.panic_on_oom = 0
vm.swappiness = 60
net.ipv4.ip_forward = 1
kernel.panic = 10
kernel.panic_on_oops = 1
EOF

sudo sysctl --system

# Verify
sysctl vm.overcommit_memory net.ipv4.ip_forward
```

Key values:
- `vm.overcommit_memory=1` — required for K8s scheduler
- `vm.panic_on_oom=0` — use OOM killer, not kernel panic
- `net.ipv4.ip_forward=1` — required for pod routing

---

## Q2 — NodePort Service (front-end / neokloud)

Add named port `http` to the existing deployment, then expose as NodePort.

```bash
# Patch the deployment to add named port
kubectl patch deployment front-end -n neokloud --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/ports",
    "value": [{"name": "http", "containerPort": 80, "protocol": "TCP"}]
  }
]'

# Expose using the named port
kubectl expose deployment front-end \
  -n neokloud \
  --name front-end-svc \
  --type=NodePort \
  --port=80 \
  --target-port=http

# Verify
kubectl get svc front-end-svc -n neokloud
kubectl describe svc front-end-svc -n neokloud | grep -E "NodePort|Port|Selector"
```

---

## Q3 — ArgoCD via Helm, No CRDs

```bash
# Add the official Argo repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Template chart v7.7.3 without CRDs, save to file
helm template argocd argo/argo-cd \
  --namespace argocd \
  --version 7.7.3 \
  --set crds.install=false \
  > /home/cloud_user/argo-helm.yaml

# Validate
helm repo list | grep argo
grep -c "kind: CustomResourceDefinition" /home/cloud_user/argo-helm.yaml  # must be 0
```

> **Note:** The correct flag is `crds.install=false` (plural), not `crd.install=false`.
> The output path (`> /home/cloud_user/argo-helm.yaml`) was missing from the original answer in Q3.txt.

---

## Q4 — Restrict NGINX to TLSv1.3 Only

Edit the ConfigMap to remove TLSv1.2 from `ssl_protocols`, then restart the deployment.

```bash
kubectl edit configmap nginx-config -n nginx-static
```

Change:
```
ssl_protocols TLSv1.2 TLSv1.3;
```
To:
```
ssl_protocols TLSv1.3;
```

Or patch directly:
```bash
kubectl get configmap nginx-config -n nginx-static -o yaml > /tmp/nginx-config.yaml
# Edit the file, then:
kubectl apply -f /tmp/nginx-config.yaml

# Restart pods to pick up ConfigMap change
kubectl rollout restart deployment/nginx-static -n nginx-static
kubectl rollout status deployment/nginx-static -n nginx-static

# Verify
curl --tls-max 1.2 https://web.k8s.local -k -v   # must FAIL (SSL alert)
curl --tlsv1.3  https://web.k8s.local -k          # must return 200
```

---

## Q5 — Restore MariaDB with PVC

```bash
# Find the existing retained PV and its storageClassName
kubectl get pv
# Note name, storageClassName, and accessModes

# Create the PVC to bind to that PV
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb
  namespace: mariadb
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 250Mi
  storageClassName: manual   # match the existing PV's storageClassName
EOF

kubectl get pvc mariadb -n mariadb   # must show Bound

# Update the deployment claimName to "mariadb"
sed -i 's/claimName: .*/claimName: mariadb/' ~/mariadb-deployment.yaml
kubectl apply -f ~/mariadb-deployment.yaml

# Verify
kubectl get pods -n mariadb
kubectl describe pvc mariadb -n mariadb | grep -E "Status|Volume"
```

---

## Q6 — Fix Gateway API YAML (Duplicate `listeners` Key)

**Bug:** The YAML has two separate `listeners:` keys — YAML silently drops the first one. Merge them into a single list.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: example-gateway
spec:
  gatewayClassName: example-class
  listeners:                    # single key with both entries
  - name: http
    protocol: HTTP
    port: 80
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: app-cert
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: example-httproute
spec:
  parentRefs:
  - name: example-gateway
  hostnames:
  - "www.example.com"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /login
    backendRefs:
    - name: example-svc
      port: 8080
```

```bash
kubectl apply --dry-run=server -f gateway.yaml
kubectl get gateway example-gateway
kubectl get httproute example-httproute
```

---

## Q7 — PriorityClass (highest − 1) + Patch Deployment

```bash
# Find the highest existing user-defined PriorityClass value
kubectl get priorityclass --sort-by=.value \
  -o custom-columns="NAME:.metadata.name,VALUE:.value"
# System classes (system-cluster-critical=2000000000, system-node-critical=2000001000)
# are irrelevant — look at user-defined ones only

# Example: highest user-defined = 1000 → create value 999
kubectl apply -f - <<EOF
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 999
globalDefault: false
description: "High priority for user workloads"
EOF

# Patch the deployment
kubectl patch deployment busybox-logger -n priority --type=merge \
  -p '{"spec":{"template":{"spec":{"priorityClassName":"high-priority"}}}}'

# Verify
kubectl rollout status deployment/busybox-logger -n priority
kubectl get pods -n priority -o custom-columns="POD:.metadata.name,PC:.spec.priorityClassName"
```

---

## Q8 — HPA with 30s Downscale Stabilization

```yaml
# hpa-neokloud.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: neokloud-server
  namespace: auto-scale
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: neokloud-server
  minReplicas: 1
  maxReplicas: 4
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 30
```

```bash
kubectl apply -f hpa-neokloud.yaml

# Verify
kubectl get hpa neokloud-server -n auto-scale
kubectl describe hpa neokloud-server -n auto-scale | grep -A4 "scaleDown"
```

---

## Q9 — Default StorageClass (WaitForFirstConsumer)

```bash
# If another default StorageClass exists, un-default it first
CURRENT_DEFAULT=$(kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
if [ -n "$CURRENT_DEFAULT" ]; then
  kubectl patch storageclass "$CURRENT_DEFAULT" \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
fi

# Create the new default StorageClass
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
EOF

# Verify
kubectl get storageclass | grep local-path
# Should show (default) next to local-path
```

---

## Q10 — CNI Selection for NetworkPolicy

**Answer: Calico** — Flannel has no NetworkPolicy engine.

```bash
# Install Calico via Tigera Operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/tigera-operator.yaml

kubectl rollout status deployment/tigera-operator -n tigera-operator --timeout=120s

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/custom-resources.yaml

# Wait for all calico pods
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n calico-system --timeout=300s

# Confirm CNI is functional
kubectl get nodes   # should show Ready
```

Why not Flannel: Flannel is a pure L3 overlay; NetworkPolicy enforcement requires a separate policy engine (like Calico).

---

## Q11 — Migrate Ingress → Gateway API

```bash
# Step 1: inspect the existing Ingress to find hostname, TLS secret, backend service/port
kubectl get ingress web -o yaml
```

```yaml
# Apply after replacing placeholders with values from the Ingress
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
spec:
  gatewayClassName: nginx          # pre-installed GatewayClass
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: gateway.web.k8s.local
    tls:
      mode: Terminate
      certificateRefs:
      - name: <TLS-SECRET-FROM-INGRESS>   # e.g. web-tls
        kind: Secret
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-route
spec:
  parentRefs:
  - name: web-gateway
  hostnames:
  - gateway.web.k8s.local
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: <BACKEND-SERVICE-FROM-INGRESS>   # e.g. web-svc
      port: 80
```

```bash
kubectl apply -f web-gateway.yaml

kubectl get gateway web-gateway
kubectl get httproute web-route
kubectl describe gateway web-gateway | grep -A5 "Listeners"
```

---

## Q12 — PriorityClass (highest − 1) + Patch Deployment

> Same concept as Q7. The Q12.txt patch command has a bug (malformed JSON) — correct version below.

```bash
# Get existing PriorityClass values
kubectl get priorityclass --sort-by=.value

# Example: highest = 1000 → create 999
kubectl create priorityclass high-priority \
  --value=999 \
  --description="high-priority class"

# Patch deployment — Q12.txt had broken JSON, this is correct:
kubectl patch deployment high-priority-deploy -n high-priority --type=merge \
  -p '{"spec":{"template":{"spec":{"priorityClassName":"high-priority"}}}}'

# Verify
kubectl rollout status deployment/high-priority-deploy -n high-priority
```

---

## Q14 — WordPress: Equal Resource Requests/Limits Across Init + Main Containers

```bash
# Step 1: scale to 0
kubectl scale deployment wordpress --replicas=0

# Step 2: check node allocatable capacity to size requests
kubectl describe node | grep -A6 "Allocatable:"
# Example node: CPU=2000m, Memory=4Gi
# With 3 pods + ~10% overhead: ~600m CPU, ~1.2Gi memory per pod is safe
# Task says "divide evenly" → use 33% of node capacity per pod
```

```yaml
# Apply updated deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordpress
spec:
  replicas: 3
  selector:
    matchLabels:
      app: wordpress
  template:
    metadata:
      labels:
        app: wordpress
    spec:
      initContainers:
      - name: init-myservice
        image: busybox
        command: ['sh', '-c', 'echo Initializing...']
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
      containers:
      - name: wordpress
        image: wordpress:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
```

```bash
kubectl apply -f wordpress.yaml

# Step 3: scale back to 3
kubectl scale deployment wordpress --replicas=3
kubectl rollout status deployment/wordpress
kubectl get pods -o wide
```

---

## Q15 — List Certificates Expiring Within 7 Days (cert-manager)

```bash
# List all certificates with their expiry
kubectl get certificates -A \
  -o custom-columns="NAMESPACE:.metadata.namespace,NAME:.metadata.name,EXPIRY:.status.notAfter,READY:.status.conditions[0].status"

# Find ones expiring within 7 days (pure kubectl + shell, no third-party tools)
kubectl get certificates -A -o json | \
python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
threshold = datetime.now(timezone.utc) + timedelta(days=7)
for c in json.load(sys.stdin)['items']:
    exp = c.get('status', {}).get('notAfter', '')
    if not exp:
        continue
    exp_dt = datetime.fromisoformat(exp.replace('Z','+00:00'))
    ns   = c['metadata']['namespace']
    name = c['metadata']['name']
    tag  = 'EXPIRING SOON' if exp_dt <= threshold else 'OK'
    print(f'{tag:13}  {ns}/{name}  expires={exp}')
"
```

---

## Q16 — NetworkPolicy: Allow Only neok8s → neokloud

```bash
# Step 1: remove existing policy
kubectl get networkpolicies -n neokloud
kubectl delete networkpolicy --all -n neokloud

# Step 2: apply restrictive policy
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-neok8s-only
  namespace: neokloud
spec:
  podSelector:
    matchLabels:
      app: cloud-app
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: neok8s
EOF

# Step 3: verify
kubectl get networkpolicy -n neokloud

# Test — neo → neokloud must FAIL
NEO_POD=$(kubectl get pod -n neo -l app=neo-app -o jsonpath='{.items[0].metadata.name}')
CLOUD_IP=$(kubectl get pod -n neokloud -l app=cloud-app -o jsonpath='{.items[0].status.podIP}')
kubectl exec -n neo $NEO_POD -- curl -m 3 $CLOUD_IP   # expected: timeout

# Test — neok8s → neokloud must SUCCEED
K8S_POD=$(kubectl get pod -n neok8s -l app=k8s-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n neok8s $K8S_POD -- curl -m 3 $CLOUD_IP   # expected: 200
```

---

## Q17 — Fix kube-apiserver: Wrong etcd Port (2380 → 2379)

```bash
# Inspect current static pod manifest
grep "etcd" /etc/kubernetes/manifests/kube-apiserver.yaml

# Fix: replace peer port 2380 with client port 2379
sudo sed -i 's/:2380/:2379/g' /etc/kubernetes/manifests/kube-apiserver.yaml

# kubelet auto-restarts the static pod (wait ~30s)
watch kubectl get pods -n kube-system -l component=kube-apiserver
```

Also verify cert paths — they must point to **client** certs, not peer certs:

```bash
grep -E "etcd-cafile|etcd-certfile|etcd-keyfile" /etc/kubernetes/manifests/kube-apiserver.yaml
```

Expected (correct):
```
--etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
--etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt   ← client cert
--etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
```

Wrong (peer certs — causes cert mismatch):
```
--etcd-certfile=/etc/kubernetes/pki/etcd/peer.crt   ← wrong
```

Validate after fix:
```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/apiserver-etcd-client.crt \
  --key=/etc/kubernetes/pki/apiserver-etcd-client.key \
  endpoint health
```

---

## Exam Day Aliases

```bash
alias k=kubectl
export do="--dry-run=client -o yaml"

# Quick resource generation
k create deployment test --image=nginx $do
k create service nodeport mysvc --tcp=80:80 $do

# Context switch
kubectl config use-context <name>
kubectl config get-contexts

# Force delete stuck pod
kubectl delete pod <name> --grace-period=0 --force

# Check RBAC
kubectl auth can-i create pods \
  --as=system:serviceaccount:default:mysa -n mynamespace
```
