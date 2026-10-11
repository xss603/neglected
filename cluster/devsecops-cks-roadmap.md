# DevSecOps + CKS Roadmap

Study/implementation roadmap mapped against the CKS (Certified Kubernetes
Security Specialist) exam domains, cross-referenced to what's **already
running on this cluster** vs. still a gap. Use as a checklist, not a
one-shot task — each domain lists the repo artifact that proves it, or
the next concrete step if there isn't one yet.

## 1. Cluster Setup (10%)
- [x] CIS benchmark awareness — k3s ships hardened defaults; no `kube-bench`
      run tracked in-repo yet. **Next**: run `kube-bench run --targets k3s`
      on the server, commit findings to `cluster/debug-k8s/`.
- [x] Network policy baseline — verify Traefik/ingress NetworkPolicies exist
      (`networking/`). **Gap**: no default-deny NetworkPolicy per namespace.
- [ ] Ingress TLS — cert-manager present (see runbook §4); confirm no
      wildcard/self-signed certs slip into prod-facing routes.

## 2. Cluster Hardening (15%)
- [x] RBAC least privilege — audit command in
      `cluster/devsecops-kubeadmin-runbook.md` §2.
- [x] Restrict API server access — k3s single-node, SSH-only mgmt per
      CLAUDE.md (no public API exposure assumed — verify with
      `kubectl cluster-info` from outside the VPN/SSH tunnel).
- [ ] Upgrade cadence — no documented k3s version pin/upgrade policy.
      **Next**: add a `cluster/` note on current k3s version + upgrade plan.

## 3. System Hardening (15%)
- [ ] Minimize host attack surface — no seccomp/AppArmor profile audit
      tracked. **Next**: `kubectl get pod -A -o yaml | grep -i seccomp`.
- [x] Kernel hardening sharp edge already hit — see CLAUDE.md
      "kubelet CLI flags are version-sensitive" (real outage, don't repeat).

## 4. Minimize Microservice Vulnerabilities (20%)
- [x] Admission control — Kyverno (`manifests/kyverno-policies/`),
      `failurePolicy: Ignore` convention for Audit-only policies.
- [x] Image signing/verification — `docs/cosign-sigstore.md` (keyless +
      key-based cosign, Kyverno `verifyImages` example, currently `Audit`
      only — **gap**: not yet `Enforce`).
- [ ] Secrets at rest — Vault running (`apps/vault.yaml`) but check
      encryption-at-rest config on etcd itself (`EncryptionConfiguration`).
- [x] Pod Security — security context audit command in runbook §2.

## 5. Supply Chain Security (20%)
- [x] Image scanning — Trivy operator (`operators/trivy-operator/`) +
      monthly S3 backup CronWorkflow (`workflows/trivy-reports-backup-cron.yaml`).
- [x] Signed images — `docs/cosign-sigstore.md`.
- [ ] SBOM generation — `cosign attest` documented but no CI pipeline
      wired yet. **Next**: add SBOM step to the GitHub Actions sign job.
- [x] Registry access control — `registry-cli/` (JFrog/IBM CR),
      `inject-registry-access-secret.yaml` Kyverno policy.

## 6. Monitoring, Logging, Runtime Security (20%)
- [x] Observability — Grafana dashboards (`observability/grafana-dashboards/`),
      SigNoz (`apps/signoz.yaml`, manually scaled per RAM pressure).
- [ ] Runtime threat detection (Falco or similar) — **not present**. Given
      8GB RAM constraint, evaluate `falco` lightweight eBPF mode before
      adding; budget RAM against SigNoz/ClickHouse first (CLAUDE.md
      resource-constraint rule).
- [x] Audit logging — confirm k3s `--kube-apiserver-arg=audit-log-path=...`
      is set; not currently tracked in this repo — **gap**.

## Rollout order (respects sync-wave + RAM constraints)
1. Close CIS/kube-bench gap (read-only, zero RAM cost).
2. Flip existing Kyverno image-verify policy from `Audit` → `Enforce`
   after a soak period (zero new RAM).
3. Default-deny NetworkPolicies per namespace (zero RAM cost, test on a
   non-critical namespace first — Traefik/cert-manager/Vault are the
   blast-radius risks per CLAUDE.md).
4. Audit logging config (zero RAM, control-plane only).
5. Falco **last** — only if `kubectl top node` shows headroom; this is the
   one item with real resource cost on a single 8GB node.

## Validation
After any policy change: use the standard ArgoCD hard-refresh + sync loop
in CLAUDE.md "Verifying changes" — a `Synced` Application is not proof;
confirm the actual admission/deny behavior with a test pod.
