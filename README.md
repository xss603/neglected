# Neglected repository

This repo is organized by the systems and workflows it documents.

## Structure

- `apps/` — application and service-specific assets
  - `agentgateway/`
  - `startlette/`
- `cluster/` — cluster operations, debugging, support scripts, and runbooks
  - `argo/`
  - `debug-k8s/`
  - `scripts/`
  - `devsecops-kubeadmin-runbook.md`
- `networking/` — ingress, gateway, and networking incident notes
  - `kgateway/`
  - `traefik-incident-analyse/`
- `observability/` — dashboards and telemetry artifacts
  - `dremio/`
  - `grafana-dashboards/`
- `operators/` — operator-related notes and docs
  - `operator-sdk/`
- `manifests/` — cluster-scoped manifests and policy resources
  - `kyverno-policies/`
- `workflows/` — backup and workflow manifests
  - `wkf-qdrant-bkp/`

## Notes

- Keep machine-specific runtime artifacts out of the tracked repo when possible.
- Prefer placing new files alongside the subsystem they belong to rather than in the repo root.
- `CLAUDE.md` remains at the root and contains operational guidance for this workspace.
- `manifests/kyverno-policies/inject-registry-access-secret.yaml` adds the `registry-access`
  imagePullSecret to Pods plus Deployment, StatefulSet, DaemonSet, Job, and CronJob templates in
  namespaces labeled `registry-access.xss603.io/inject=true`; the Secret itself must already exist in each target
  namespace and must not be committed to this repository. Because the policy only mutates new
  admissions, existing workloads in opted-in namespaces must be restarted to pick up the secret.
