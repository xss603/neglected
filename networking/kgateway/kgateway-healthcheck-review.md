# Review: `kgateway-healthcheck.sh`

Verdict: yes, this will genuinely help debug a Gateway/HTTPRoute issue — the layering
(status → GatewayParameters → Service → Endpoints → pod socket bind → Envoy xDS →
HTTPRoute status → backend port mapping → LB/firewall) matches the real dependency
chain. Found real bugs and coverage gaps, fixed in `kgateway-healthcheck.sh` in this
same repo.

## Bugs (would break the script mid-run)

1. **`set -u` + unassigned `$EXT_IP` → hard crash.** `EXT_IP` is only ever set inside
   the `else` branch of the pod/svc lookup (section 3). If that lookup fails, section 9
   references `$EXT_IP` under `set -u` and the script dies right there — silently
   losing the LB/firewall hint *and* the "DONE" banner, with no clue why it stopped.
   Fixed by pre-initializing `EXT_IP="unknown"` before it's ever conditionally set.

2. **Leaked `kubectl port-forward` on any non-happy-path exit.** `PF_PID` is only
   killed at the bottom of its own block. Ctrl-C, or any error between starting the
   port-forward and that kill line, leaves an orphan `kubectl port-forward` running.
   Fixed with `trap cleanup EXIT`.

3. **`items[0]` silently assumes one Gateway pod.** Scale replicas and it picks an
   arbitrary one without saying so. Fixed with a pod-count check that warns when
   there's more than one.

4. **Sections 7/8 don't filter by `$GW`.** They dump every HTTPRoute in the namespace
   regardless of which Gateway it actually `parentRefs`s — noisy and misleading the
   moment the namespace hosts more than one Gateway. Fixed by filtering on
   `.spec.parentRefs[].name == $GW`.

## Gaps (missing checks that are the actual root cause most of the time)

5. **No GatewayClass check at all.** This is the single most common real-world root
   cause in this whole class of problem: kgateway's chart does not create a
   `GatewayClass` on install, and a Gateway referencing an unaccepted/nonexistent
   class will sit un-Programmed forever with everything downstream looking fine.
   Added as step 0, before anything else.

6. **No preflight for `kubectl`/`jq`/`curl`.** Fails with a confusing mid-script error
   instead of a clear one on a bare jump host. Added an early `command -v` check.

7. **Fixed `/tmp/*.json` filenames and a hardcoded local port 19000.** Two concurrent
   runs (two gateways, two engineers) collide. Fixed with `mktemp -d` for scratch files
   (still using a fixed local admin port since that's inherent to `port-forward`, but
   at least parameterized as `$3` now instead of hardcoded).

8. **Fixed `sleep 2` before hitting the admin API.** Coin flip on a slower cluster or
   under load. Replaced with a poll loop (10 x 0.5s, checking `/ready` for `LIVE`)
   that also reports the port-forward log path on failure instead of a bare warning.

## Not changed, but worth knowing when reading the output

- Section 5's `ss`/`netstat` exec will legitimately fail on a distroless Envoy image
  (no shell) — that's expected, not a real problem; the fixed script's warning now
  says so explicitly and points at section 6 (admin API) as the real source of truth
  for port-bind state.
- Section 6 assumes Envoy admin on port 19000, kgateway's default — some builds/older
  charts expose 9901 instead; now overridable via `$3` instead of requiring an edit.
- Section 8 assumes numeric `backendRefs[].port` (correct per the Gateway API spec —
  it's always a Service port number, never a name), so no bug there, just confirming
  it for anyone auditing this.
