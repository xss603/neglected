# ClusterIP works, domain via LB doesn't — isolating DNS vs LB vs Gateway

Confirmed: the Service→pod path is fine (ClusterIP answers HTTP in-cluster). The break is specifically between DNS/domain and the LB VIP. Narrow it further:

## 1. Does the domain actually resolve to the LB's real IP?
```bash
dig +short <domain>
kubectl get svc -n <gateway-ns> -o wide   # find the LoadBalancer-type Service, check EXTERNAL-IP
```
If these don't match, it's pure DNS — wrong/stale A record, or DNS still pointing at an old LB IP from a previous Gateway/Ingress. Nothing k8s-side will fix that.

## 2. If DNS is correct, does anything actually answer on that IP at all?
```bash
curl -v http://<LB-external-ip>:<port>   # bypass DNS entirely, hit the IP directly
```
- **Refused/timeout even by raw IP** → the LB itself isn't up, or nothing's listening there. On k3s specifically, "LoadBalancer" is usually ServiceLB (Klipper) doing a host-port bind — check the actual proxy pod is Running on a node and that port is genuinely bound:
  ```bash
  kubectl get pods -n <gateway-ns> -l gateway.networking.k8s.io/gateway-name=<name> -o wide
  kubectl get svc -n <gateway-ns> <lb-svc> -o yaml   # check .status.loadBalancer.ingress
  ```
  Empty `.status.loadBalancer.ingress` = the LB never actually provisioned — very common with `GatewayParameters` not wired to the `GatewayClass` correctly, so it silently fell back to `ClusterIP` instead of `LoadBalancer` and there's no external IP to answer at all.
- **Raw IP answers, but domain still doesn't** → it really is DNS (step 1), or a TLS SNI mismatch if testing HTTP but the Gateway listener is HTTPS-only with strict SNI routing (curl the IP with `-H "Host: <domain>"` or `--resolve <domain>:<port>:<LB-IP>` to simulate the real request instead of bypassing the hostname entirely).

## 3. If it's a cloud LB (not k3s ServiceLB), check the LB's own health checks
```bash
kubectl describe svc <lb-svc> -n <gateway-ns>   # events often show provisioning errors
```
Cloud LBs (AWS NLB/ALB, GCP LB, etc.) run their own health checks against node ports — if `externalTrafficPolicy: Local` and the node the LB is checking has no local ready endpoint, the LB marks that target unhealthy and refuses/drops externally even though everything internal is fine.

**Fastest single command to run next**: `curl -v --resolve <domain>:443:<LB-IP> https://<domain>` — this isolates DNS from everything else in one shot. If that also fails, you know for certain it's the LB/Gateway layer, not DNS.
