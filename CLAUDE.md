# k3s-gitops

GitOps config for the k3s cluster on `<SERVER_IP>` (SSH port `22`).
Read [README.md](README.md) first for structure, components, and the
"Manual cluster state" section — this file is behavioral conventions for
Claude, not a restatement of that.

## Hard rules

- **Nothing is `kubectl apply`d by hand** except `bootstrap/root-app.yaml`
  (the one-time seed). Every other change goes: edit YAML → commit → push
  → let ArgoCD reconcile (or hard-refresh/sync it, see below). Never patch
  a live resource directly and call it done — the git state must reflect
  reality or the next `selfHeal` silently reverts it.
- **No secrets in git, ever.** Passwords, tokens, client secrets — all
  live only as cluster Secrets (`existingSecret`/`envValueFrom` in the
  git-tracked values, never the value itself) or, for genuinely
  interactive one-time bootstrap (Vault unseal, OIDC client creation),
  directly on the cluster. If a change requires typing a real secret
  value anywhere, that value does not go in this repo.
- **`argocd.argoproj.io/sync-wave` ordering is load-bearing.** Before
  adding a wave number, check the README's "Sync waves" table — a new
  Application with a CRD dependency (like `kyverno-policies` needing
  Kyverno's own CRDs) must sync in a later wave than whatever creates
  that dependency.
- **Check `automated.selfHeal` before manually changing live cluster
  state.** If it's on, ArgoCD will revert a manual `kubectl scale`/`patch`
  within its next reconcile — confirmed directly with SigNoz (see
  `apps/signoz.yaml`'s comment). Either change git instead, or the
  Application deliberately has no `automated` block (SigNoz's pattern) so
  manual drift is allowed to stick.

## This is a real, resource-constrained production box

8GB RAM, single node. This isn't a lab you can freely oversize:
- Every new component needs explicit `resources.requests`/`limits` sized
  to real usage (`kubectl top`), not chart defaults — chart defaults are
  often absent or wrong (SigNoz shipped with requests but zero limits;
  ClickHouse was observed using 6x its request before anyone noticed).
- Before adding anything with a background controller / extra sidecar /
  HA replica count, ask whether this box actually needs that mode — see
  how Kyverno was deployed with `backgroundController`/`cleanupController`
  disabled specifically because the training goal didn't need them.
- SigNoz is intentionally scaled to 0 by hand whenever RAM is tight — it
  has no `automated` sync policy so this sticks. Check `kubectl -n signoz
  get pods` before assuming it's running.

## Verifying changes

This is a live cluster reachable only over SSH — there is no CI. "It's
in git" is not "it's working." Standard verification loop after any
change:

```bash
ssh root@<SERVER_IP> -p 22 'kubectl annotate application <name> -n argocd argocd.argoproj.io/refresh=hard --overwrite'
ssh root@<SERVER_IP> -p 22 'kubectl -n argocd patch application <name> --type merge -p "{\"operation\":{\"initiatedBy\":{\"username\":\"admin\"},\"sync\":{\"prune\":true}}}"'
# then confirm sync+health status, and check the actual resource (pod restarts, resource limits landed, service responds) - not just "Synced"
```

A `Synced` Application does not by itself mean the change is safe —
verify the actual rollout (new pod Ready, old pod terminated cleanly, no
crash loop) before considering a task done, especially for anything that
touches Traefik, cert-manager, or Vault (breaking any of those has
cluster-wide blast radius).

## Known sharp edges (hit for real this session, not hypothetical)

- **kubelet CLI flags are version-sensitive.** `--memory-swap-behavior`
  doesn't exist as a CLI flag on this kubelet version (only via
  `KubeletConfiguration` file) — guessing at kubelet-arg names caused a
  real ~3 minute control-plane outage. Verify a flag exists on this exact
  kubelet version before adding it to `/etc/rancher/k3s/config.yaml`.
- **Vault's StatefulSet uses `updateStrategy: OnDelete`**, deliberately —
  it needs re-unseal after any pod restart. A resources/values change to
  `apps/vault.yaml` will not take effect until the pod is manually
  deleted and re-unsealed with the keys in `/root/vault-init-output.json`
  on the server (not in this repo).
- **A Helm chart values key can silently do nothing** on a specific
  packaged chart version with zero error (Traefik's `tracing:` key on
  chart `40.1.3` — see `manifests/k3s-addons-config/traefik-tracing.yaml`).
  After applying a values change, confirm it actually rendered into the
  live resource (`kubectl get deploy ... -o jsonpath='{.spec.template.spec.containers[0].args}'`
  or equivalent) — don't trust that a Job completing means the values
  were consumed correctly.
- **Kyverno's per-policy `failurePolicy` defaults to `Fail`.** For any
  policy that's `Audit`-only, set `failurePolicy: Ignore` explicitly —
  otherwise a restart of the (single-replica) admission-controller pod
  can block all matched resource creation cluster-wide, for a policy that
  was never going to deny anything anyway.
