# Gateway API (kgateway) troubleshooting — Gateway / HTTPRoute / GatewayParameters + nginx down

Since this is a different environment, check top-down — each layer gates the next.

## 1. DNS actually resolves to the Gateway's LB/IP
```bash
dig +short <your-host>
kubectl get gateway <name> -n <ns> -o jsonpath='{.status.addresses}'
```
If these don't match, nothing downstream matters yet.

## 2. Gateway status — is it actually Programmed?
```bash
kubectl get gateway <name> -n <ns> -o yaml
```
Check `status.conditions` for `Programmed: True` and `Accepted: True`. Common kgateway-specific failure: **no `GatewayClass` exists**, or the Gateway references a class kgateway's controller doesn't own. kgateway's chart does **not** create a `GatewayClass` on install (confirmed directly against its templates) — you must create it yourself:
```bash
kubectl get gatewayclass
```
If empty or not `Accepted`, that's your root cause right there — the Gateway will sit un-programmed forever.

## 3. `GatewayParameters` actually wired to the GatewayClass
GatewayParameters only takes effect if the GatewayClass's `parametersRef` points at it:
```bash
kubectl get gatewayclass <name> -o jsonpath='{.spec.parametersRef}'
```
If missing/misnamed, your GatewayParameters (e.g. Service type LoadBalancer) is silently ignored and the auto-provisioned Envoy Service falls back to chart defaults (often `ClusterIP` — no external IP at all, which alone would fully explain "URL is down").

## 4. The listener's TLS cert
```bash
kubectl get gateway <name> -n <ns> -o jsonpath='{.spec.listeners}' | jq
kubectl get secret <cert-secret> -n <ns>
```
Confirm: the wildcard cert's Secret exists **in the same namespace as the Gateway**, `type: kubernetes.io/tls`, and actually covers the hostname in your listener (`*.example.com` doesn't cover `foo.bar.example.com` — two-level wildcards aren't real). If it's cert-manager-issued, check the `Certificate` resource itself is `Ready: True`, not just that a Secret exists (a Secret can exist and be empty/stale mid-issuance).

## 5. HTTPRoute actually attached to the Gateway
```bash
kubectl get httproute <name> -n <ns> -o yaml
```
Look at `status.parents[].conditions` — needs `Accepted: True` **and** `ResolvedRefs: True`. A very common miss: the HTTPRoute's `parentRefs[].sectionName` doesn't match any listener name, or the listener has an `allowedRoutes.namespaces` restriction that excludes the HTTPRoute's namespace.

## 6. Service/Endpoints/Pod, bottom of the stack
```bash
kubectl get endpoints <svc> -n <ns>   # empty = zero ready pods, most common actual cause
kubectl get pod -l <selector> -n <ns>
kubectl describe pod <nginx-pod> -n <ns>   # probe failures, image pull, crash
```
Empty endpoints is the single most common real reason a Gateway looks fine but the URL 404s/hangs — the HTTPRoute's `backendRefs` Service has no ready pods behind it (readiness probe failing is the usual suspect).

## 7. NetworkPolicy — the one that bites people who've done everything else right
If there's a default-deny NetworkPolicy in the namespace, remember: **kgateway's auto-provisioned Envoy proxy runs in the Gateway's own namespace**, not a shared `kgateway-system` — easy to get backwards. Confirm where the proxy pod actually lives:
```bash
kubectl get pods -n <gateway-namespace> -l gateway.networking.k8s.io/gateway-name=<name>
```
Then check whether your backend pod's NetworkPolicy has an ingress allow matching that proxy pod's namespace+labels — a `namespaceSelector` pointing at `kgateway-system` when the proxy is actually same-namespace silently blocks all traffic with no visible error anywhere in the Gateway/HTTPRoute status.

---

**Fastest path to the actual cause**: run steps 2, 5, and 6 first (`kubectl get gateway/httproute -o yaml` status blocks + `kubectl get endpoints`) — between those three you'll almost always see the real failure directly in a `status.conditions[].message`, rather than guessing.
