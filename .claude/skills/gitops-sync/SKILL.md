---
name: gitops-sync
description: Force an ArgoCD Application to hard-refresh and sync on the k3s cluster, then report its resulting sync/health status. Use after pushing a change to apps/ or manifests/ in this repo when you don't want to wait for ArgoCD's normal poll interval.
---

# gitops-sync

Reconciling a change in this repo means: it's committed and pushed to
`main`, then ArgoCD picks it up either on its own poll interval or
immediately if forced. This skill does the forcing and reports back
whether it actually landed healthy — "Synced" alone doesn't mean the
rollout succeeded, so always check pods too for anything non-trivial.

## Steps

1. Confirm the change is committed and pushed (`git status`, `git log
   -1`). If not, stop and push first — syncing before pushing just
   re-applies the old state.

2. Hard-refresh and sync the named Application:

   ```bash
   ssh root@<SERVER_IP> -p 22 "
     kubectl annotate application <APP_NAME> -n argocd argocd.argoproj.io/refresh=hard --overwrite
     kubectl -n argocd patch application <APP_NAME> --type merge -p '{\"operation\":{\"initiatedBy\":{\"username\":\"admin\"},\"sync\":{\"prune\":true}}}'
   "
   ```

3. Wait ~15-30s, then check status:

   ```bash
   ssh root@<SERVER_IP> -p 22 "kubectl -n argocd get application <APP_NAME> -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}'"
   ```

4. **Don't stop at "Synced Healthy".** For anything that changed a
   Deployment/StatefulSet spec (image, resources, env), also check the
   actual pods:

   ```bash
   ssh root@<SERVER_IP> -p 22 "kubectl -n <NAMESPACE> get pods"
   ```

   Look for: new pod reaching `Ready`, old pod terminating cleanly, no
   restart-count bump, no `CrashLoopBackOff`. If the resource is
   `OnDelete`-strategy (Vault) or otherwise doesn't auto-roll on a spec
   change, say so explicitly rather than reporting success on a stale pod.

5. If the app has no `automated` sync policy (currently only
   `apps/signoz.yaml`), a sync will also reassert any replica counts set
   in the chart/values — including scaling back up something that was
   manually scaled to 0. Warn before syncing an app in that state, and
   re-apply the manual scale-down afterward if that's still the intent.

## Common failure: still OutOfSync after a sync

Usually one of:
- The chart's own controller hasn't reconciled a downstream CR yet (e.g.
  Kyverno's ClusterPolicy values need clickhouse-operator running to
  propagate into the actual StatefulSet - check the operator's own pod
  status, not just the Application).
- A resource this Application owns has `ignoreDifferences` for unrelated
  fields (see `apps/vault.yaml`'s webhook caBundle exclusion) - if the
  diff is in an excluded field, it's expected and not an error.
- Genuine manual drift (SigNoz scaled to 0 while chart defaults to 1) -
  this is by design for that one Application, not a bug.
