# trivy-operator: no VulnerabilityReports found

## Most likely cause

`VulnerabilityReport` is a namespaced CRD. `kubectl get vulnerabilityreports`
without `-A` only checks the current context's namespace (usually `default`),
which is why it comes back empty even when the operator is scanning fine.
Otherwise, scan jobs are failing or haven't completed yet.

Run [`triage.sh`](./triage.sh) (read-only) to check, in order: reports
cluster-wide, operator log errors, scan job/pod state, recent scan job logs,
and the operator's scanner/namespace config.

```bash
./triage.sh trivy-system
```

## Common fixes

See [`values-fix.yaml`](./values-fix.yaml) for the Helm values that usually
fix this:

- `targetNamespaces: ""` - scope was narrower than "all namespaces".
- `scanJobsConcurrentLimit` raised - jobs queued but never scheduled.
- `dbRepository`/`javaDbRepository` pointed at `mirror.gcr.io` - avoids
  `ghcr.io` TOOMANYREQUESTS rate limits on the trivy-db pull.

This repo has no live ArgoCD `Application` for trivy-operator yet, so these
values are a reference, not something applied from here. If trivy-operator
gets its own `apps/trivy-operator.yaml` in the future, these keys belong in
that Application's `helm.values` in git - never a manual `helm upgrade`
against the live cluster (see root `CLAUDE.md`, "Nothing is `kubectl
apply`d by hand").

## Caveats

- First scan of a workload takes a few minutes; reports only appear once the
  scan job completes.
- Private registries need `imagePullSecrets` on the scanned workload (or
  node-level registry auth) for the scanner to pull the image.
- Air-gapped/offline: the trivy-db mirror above still needs network egress
  to `mirror.gcr.io`; a fully air-gapped cluster needs a local DB mirror or
  trivy client/server mode instead.
- Reports are namespaced per scanned workload and are regenerated (not
  patched) whenever that workload's pod spec changes.
