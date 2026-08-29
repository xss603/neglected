# kgateway: connection reset via LB VIP — PROXY protocol mismatch

Root cause found for a Gateway that works when called directly but resets when
called through the load balancer's VIP hostname.

## Symptom

| Call path | Result |
|---|---|
| Service ClusterIP, `Host`/SNI = hostname declared in Gateway/HTTPRoute | **200 OK** |
| LB VIP hostname (Gateway hostname CNAMEs to it), same SNI | **connection reset** |

`externalTrafficPolicy: Cluster`. Gateway `Programmed=True`, HTTPRoute
`Accepted`/`ResolvedRefs=True`, backend healthy.

## Root cause

The load balancer had PROXY protocol v2 enabled (`proxy-protocol:
enableProxyProtocolInitiatoryv2`), so it prepends a binary PROXY v2 header
before the TLS ClientHello. The Gateway's Envoy listener had no PROXY protocol
listener filter, read the header as a malformed handshake, and reset the
connection.

Everything downstream of the LB was healthy the entire time.

### Why the ClusterIP test was the decisive clue

The ClusterIP call succeeded with a **raw TLS stream and no PROXY header**. That
proves two things at once:

- Envoy is *not* configured to expect PROXY protocol.
- Envoy *is* terminating TLS correctly, and the HTTPRoute match + backend work.

So the fault had to be a transformation applied by the LB and nothing else. Only
two transformations produce a reset after a successful TCP handshake:

1. LB prepends a PROXY protocol header (this case).
2. LB terminates TLS itself and forwards plaintext into a `tls.mode: Terminate`
   listener.

### Reset vs refused

Worth distinguishing, because it narrows the search:

- `ECONNREFUSED` — RST in response to `SYN`; nothing listening, connection never
  established.
- `ECONNRESET` — RST *after* the handshake completed; something accepted the
  connection then tore it down.

A reset rules out "no healthy target" and port mismatch, and points at the first
bytes of the stream being wrong.

## Fix (part 1 — apply this first, alone)

```yaml
apiVersion: gateway.kgateway.dev/v1alpha1
kind: ListenerPolicy
metadata:
  name: proxy-protocol
  namespace: <gw-ns>          # MUST be the Gateway's own namespace
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: <gateway-name>
  default:
    proxyProtocol:
      allowRequestsWithoutProxyProtocol: true
```

Field names verified against the live CRD schema on kgateway **v2.4.3**. Confirm
they exist on your version before applying:

```bash
kubectl explain listenerpolicies.spec.default.proxyProtocol
```

### `allowRequestsWithoutProxyProtocol` is a real decision

- `false` (strict, spec-conformant): only PROXY-prefixed connections accepted.
  **This breaks direct in-cluster access to the Service**, including the
  ClusterIP call used to diagnose the problem.
- `true` (mixed): LB traffic and direct in-cluster traffic both work. The CRD's
  own description warns this "allows clients to spoof the perceived source
  address". Only acceptable when every source that can reach the listener is
  trusted.

`true` is the safer rollout value: it fixes the VIP path without destroying the
one path known to work. Tighten to `false` afterwards, once you've confirmed
nothing legitimate connects directly.

Purely additive and trivially reversible:

```bash
kubectl delete listenerpolicy proxy-protocol -n <gw-ns>
```

## Fix (part 2 — CONDITIONAL, do not apply reflexively)

```yaml
spec:
  kube:
    envoyContainer:
      bootstrap:
        enableReadinessProbeProxyProtocol: true
```

The CRD description is explicit: set this *"if and only if the load balancer in
front of the gateway prepends PROXY protocol headers to incoming TCP connections
targeting the readiness port"* (port 8082).

Two different things connect to that readiness listener, and only one goes
through the LB:

| Prober | Path | Sends PROXY header? |
|---|---|---|
| kubelet readiness probe | node -> pod, direct | never |
| Cloud LB health check | through the LB | only if proxy-protocol covers that port |

This is why the AWS example in the docs uses
`service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: "*"` — the `*`
means all ports, which sweeps in the health-check port. A config scoped to only
the 443 listener would not.

So the question to answer about your own LB setting is: **is it per-listener, or
LB-wide?**

- LB-wide / all pools -> set the flag.
- Only the data listener -> leave it `false`.

Getting it wrong in **either** direction makes the readiness listener and its
prober disagree -> health checks fail -> pod `NotReady` -> endpoints empty ->
total outage, including the path that currently works.

## Rollout order

Apply part 1 alone, then verify — in this order:

```bash
# 1. did the policy actually attach? A ListenerPolicy targeting a misnamed
#    Gateway is accepted by the API server and then silently does nothing.
kubectl -n <gw-ns> get listenerpolicy proxy-protocol -o yaml   # check .status

# 2. the path that was broken
curl -vk --resolve <gw-hostname>:443:<VIP-IP> https://<gw-hostname>/

# 3. the reference path must STILL work
curl -vk --resolve <gw-hostname>:443:<clusterIP> https://<gw-hostname>/

# 4. pod must stay Ready
kubectl -n <gw-ns> get pods -l gateway.networking.k8s.io/gateway-name=<gw> -w
```

Outcomes:

- **VIP works, pod stays Ready** -> done. Leave part 2 off.
- **VIP works, pod flaps NotReady / LB reports unhealthy targets** -> the LB is
  proxy-protocoling the health-check port too. Now add part 2.
- **VIP still resets** -> the filter didn't attach. Check Envoy's own config:
  ```bash
  kubectl exec -n <gw-ns> <envoy-pod> -- \
    curl -s localhost:19000/config_dump | grep -A3 proxy_protocol
  ```

Never apply both parts at once: if the pod goes NotReady you won't know which
change caused it, and you'll have lost the working reference path needed to
debug it.

## Alternative

Disable PROXY protocol at the LB instead. One change, no spoofing tradeoff, no
readiness-port coupling. Only keep it enabled if something actually consumes the
real client IP (WAF rules, rate limiting, audit logging) — note that
`externalTrafficPolicy: Cluster` already SNATs the source address, which is
usually why PROXY protocol gets switched on in the first place.

## Generic diagnostic: confirming a PROXY protocol mismatch

Capture what actually arrives at the Envoy pod, then hit the VIP:

```bash
kubectl debug -n <gw-ns> <envoy-pod> -it --image=nicolaka/netshoot \
  --target=<envoy-container> -- \
  tcpdump -A -n -i any 'tcp port <targetPort>' -c 20
```

First bytes on the wire identify the problem outright:

- `PROXY TCP4 ...` (v1) or `\r\n\r\n\x00\r\nQUIT\n` (v2) -> PROXY protocol
  mismatch.
- `GET / HTTP/1.1` / `Host:` -> the LB is terminating TLS and forwarding
  plaintext.
- `\x16\x03\x01` -> a clean TLS ClientHello; the stream is fine and the reset
  originates elsewhere.
