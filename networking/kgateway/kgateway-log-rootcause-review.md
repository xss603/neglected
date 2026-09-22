# Review: `kgateway-log-rootcause.sh`

Good skeleton — capture a window, parse both sides, rank by probability. Two bugs
silently invalidate large parts of it though, and for the specific symptom
(`ERR_CONNECTION_REFUSED`) the most decisive signal was missing entirely.

## Bug 1 (critical): `--since=0s` captures the ENTIRE log history, not the window

`kubectl` only sets `SinceSeconds` on the API request when the parsed duration is
non-zero. A zero duration is silently dropped, and you get the full log buffer.

Verified empirically against a live cluster:

```
pod=argocd-repo-server-b877778b6-mpj4k
kubectl logs $POD --since=0s   -> 7895 lines
kubectl logs $POD --since=1s   -> 0 lines
kubectl logs $POD (no --since) -> 7900 lines
```

`--since=0s` is indistinguishable from no filter at all.

Impact: every conclusion framed as "pendant la fenetre" was actually computed over
hours of history. A crash from last week counts as a crash "during the 180s window";
an RBAC error from pod startup gets reported as a live finding. This turns the whole
script into a historical-noise detector rather than a correlation tool — which is the
opposite of what you want when reproducing a failure on demand.

Fix: anchor on a real timestamp taken at capture start:
```bash
START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl logs ... --since-time="$START_TS"
```

## Bug 2 (critical): hardcoded `-c envoy` + `2>&1` = silent total false negative

Two problems compounding:
- kgateway's proxy container isn't always named `envoy` (varies by chart/version).
- `> "$OUTDIR/envoy.log" 2>&1` sends kubectl's **error message** into the log file.

So if the container name is wrong, `envoy.log` contains `error: container envoy is not
valid for pod ...` and nothing else. Every subsequent `grep` finds no match, and
sections 3, 4, 5 and 8 all print green `[CLEAN]`. The script confidently reports "pas
d'echec de bind detecte" having never read a single line of Envoy's logs.

Fix: auto-detect the container from `.spec.containers[*].name` (trying `envoy`,
`envoy-wrapper`, `kgateway-proxy`, `proxy`, `gateway-proxy`, then falling back to the
first container), allow `$ENVOY_CONTAINER` to override, send stderr to a separate
`.stderr` file, and explicitly warn that a section is unreliable when that file is
non-empty.

## Bug 3: no trap — orphaned `kubectl logs -f` on Ctrl-C

Default duration is 180s. Interrupt during that `sleep` and both background follows
survive the script. Fixed with `trap cleanup EXIT INT TERM`.

## Bug 4: `grep A | grep B` drops multi-line errors

Section 1 required the error keyword *and* the object keyword on the same line. A bare
`panic:` followed by a stack trace has no `gateway`/`httproute` token on the panic line
itself, so it was filtered out — exactly the error you least want to miss. Fixed with
`-A2`/`-B1 -A1` context.

## Bug 5: `declare -A` isn't available on bash 3.2

Relevant if this is ever run from a macOS workstation rather than a Linux jump host
(default `/bin/bash` there is 3.2). Rewritten to avoid associative arrays entirely;
`bash -n` now passes on 3.2.

## Gap 1 (the big one): no "did Envoy see ANY request?" check

For a client-side `ERR_CONNECTION_REFUSED`, this is *the* branching question, and the
original never asked it:

- **Envoy logged access entries during the window** → the TCP connection reaches Envoy.
  The browser's refusal is then coming from somewhere else entirely (wrong IP/port, LB
  not actually pointing at this Gateway, a different listener) — not from "nothing is
  listening".
- **Envoy logged nothing while you were actively generating traffic** → the request
  never arrives. Root cause is strictly upstream of the pod: DNS, VIP/LB, cloud
  firewall/SG, NetworkPolicy, or a Service with no endpoints. No amount of log parsing
  will help, and that's a useful thing to be told explicitly.

Added as section 9, with the script prompting you to generate traffic *at the start* of
the capture window so it actually lands inside it.

## Gap 2: no RESPONSE_FLAGS histogram

Envoy's access-log response flags are the single most diagnostic field available, and
the original ignored them. Added a histogram over access-log lines:

```
  2 UH      # no healthy upstream
  1 UF      # upstream connection failure
  1 NR      # no route configured
```

`NR`/`NC` point at HTTPRoute→cluster translation; `UH`/`UF` point at the backend.
Verified against fixture data: correctly picks up 5 access lines out of a mixed file,
extracts `UH=2 UF=1 NR=1`, and correctly assigns no flag to the `200 -` line.

## Gap 3: crash detection by grep instead of by API

`grep -c "caught signal"` is a proxy for something the API reports exactly. Replaced
with `restartCount` from `.status.containerStatuses[]`, plus — importantly — pulling
`kubectl logs --previous` when `restartCount > 0`. On a crashloop the cause is in the
*previous* container; the current one is usually clean, so the original would have
found nothing and said "pas de crash detecte".

## Correctness note on the verdict logic

The original ranked upstream errors as a candidate root cause for connection-refused.
They aren't: once Envoy accepts a TCP connection, a broken backend produces an **HTTP
503**, not a TCP refusal. The rewritten verdict says so explicitly and redirects, rather
than sending you down a dead end. New priority order:

```
bind failure > no-traffic-reached-Envoy > RBAC > xDS NACK > CRD mismatch
  > controller reject > (upstream = explicitly NOT a connection-refused cause)
```

## Usage

```bash
./kgateway-log-rootcause.sh <controller-ns> <controller-pod> <gw-ns> <gw-pod> [duration_sec]
```

Generate traffic against the failing URL as soon as the capture window opens — the
script prints a reminder, and section 9's inference depends on it.
