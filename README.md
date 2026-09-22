# Neglected repository

This repo is organized by the systems and workflows it documents.

## Structure

- `apps/` — application and service-specific assets
  - `agentgateway/`
  - `startlette/`
- `cluster/` — cluster operations, debugging, and support scripts
  - `argo/`
  - `debug-k8s/`
  - `scripts/`
- `networking/` — ingress, gateway, and networking incident notes
  - `kgateway/`
  - `traefik-incident-analyse/`
- `observability/` — dashboards and telemetry artifacts
  - `dremio/`
  - `grafana-dashboards/`
- `operators/` — operator-related notes and docs
  - `operator-sdk/`
- `workflows/` — backup and workflow manifests
  - `wkf-qdrant-bkp/`

## Notes

- Keep machine-specific runtime artifacts out of the tracked repo when possible.
- Prefer placing new files alongside the subsystem they belong to rather than in the repo root.
- `CLAUDE.md` remains at the root and contains operational guidance for this workspace.
