# DevSecOps + Kubeadmin Runbook (k3s + ArgoCD)

Practical baseline for operating this cluster safely and consistently.

## 1) Change workflow (GitOps-first)

1. Edit manifests in git.
2. Commit and push.
3. Let ArgoCD reconcile (or hard refresh/sync when needed).
4. Verify workload behavior after sync (not only `Synced` status).

> Do not rely on direct live mutation for steady state. Keep desired state in git.

## 2) Security baseline checks

### Secrets hygiene
- Never commit secret values.
- Use `existingSecret`/secret references in tracked manifests.
- Validate no credentials were added before commit.

### RBAC least privilege
- List risky bindings:
  ```bash
  kubectl get clusterrolebinding -o wide
  kubectl get rolebinding -A
  ```
- Review over-privileged subjects (`cluster-admin`, wildcard verbs/resources).

### Pod hardening
- Confirm security context is present for critical workloads:
  ```bash
  kubectl get deploy,statefulset -A -o yaml | grep -E "runAsNonRoot|readOnlyRootFilesystem|allowPrivilegeEscalation"
  ```
- Check resource requests/limits exist:
  ```bash
  kubectl get pod -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{" req="}{.spec.containers[*].resources.requests}{" lim="}{.spec.containers[*].resources.limits}{"\n"}{end}'
  ```

## 3) Operational health checks (single-node 8GB constraints)

### Node pressure
```bash
kubectl top node
kubectl top pod -A --sort-by=memory | head -n 20
kubectl get events -A --sort-by=.lastTimestamp | grep -Ei "oom|evict|pressure"
```

### Control-plane and core services
```bash
kubectl -n kube-system get pods
kubectl -n argocd get applications
kubectl -n cert-manager get pods
kubectl -n vault get pods
```

## 4) ArgoCD drift and sync verification

### App status summary
```bash
kubectl -n argocd get applications
```

### Force refresh + sync (when urgent)
```bash
kubectl annotate application <app> -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd patch application <app> --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"prune":true}}}'
```

### Post-sync verification
- Confirm new pod is `Ready`.
- Confirm old pod terminated cleanly.
- Confirm expected config/resource values landed in the live object.
- Check logs for crash loops or repeated restarts.

## 5) Incident triage quick commands

```bash
kubectl get pods -A
kubectl describe pod -n <ns> <pod>
kubectl logs -n <ns> <pod> --previous
kubectl get events -A --sort-by=.lastTimestamp | tail -n 100
```

For network incidents:
```bash
kubectl get svc,ep -A
kubectl -n <ns> exec -it <pod> -- sh
```

## 6) Safe rollback options

- Revert manifest changes in git and sync again.
- If Helm-backed app supports revision rollback, use ArgoCD app rollback flow.
- For workload-only regressions:
  ```bash
  kubectl rollout undo deployment/<name> -n <ns>
  ```

Always follow rollback with health verification and event/log review.
