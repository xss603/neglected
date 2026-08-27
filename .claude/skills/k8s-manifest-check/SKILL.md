---
name: k8s-manifest-check
description: Validate YAML syntax and run the repo's own Kyverno/OPA policies (in Audit mode) against changed manifests in apps/ or manifests/ before committing. Use before pushing any change to this repo, or when asked to check/lint/validate a manifest.
---

# k8s-manifest-check

This repo has no CI - a syntax or policy mistake isn't caught until
ArgoCD tries to render it against the live cluster, or worse, applies it
successfully but wrong. Run this before pushing anything in `apps/` or
`manifests/`.

## Steps

1. **YAML syntax.** Every changed file, especially ones with embedded
   Helm `values: |` block scalars (indentation mistakes inside these are
   the easiest way to break an Application without any tool complaining
   until ArgoCD tries to sync):

   ```bash
   python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" $(git diff --name-only --cached -- 'apps/*.yaml' 'manifests/*.yaml')
   ```

   For Application resources with embedded Helm values specifically,
   also extract and validate the nested `spec.source.helm.values` block
   as its own YAML document - a syntax error there won't fail the outer
   parse, it'll just silently produce wrong/empty Helm values.

2. **Kyverno/conftest policy check**, using this repo's own training
   policies (`training/devsecops/opa/`) against any plain Pod-producing
   manifest changed (mostly relevant to `manifests/kyverno-policies/`
   itself and any new workload manifest, less so to Application CRs):

   ```bash
   conftest test <changed-file> -p training/devsecops/opa/
   ```

   These are advisory (the live Kyverno policies are Audit mode too) -
   report findings, don't block on them, unless the user asked for
   Enforce-strength gating.

3. **Resource requests/limits check** for anything adding or modifying a
   Helm `values:` block with a `resources:` key (or lacking one): confirm
   both `requests` and `limits` are set, not just one. This is the single
   most common real mistake made in this repo (SigNoz shipped with
   requests but zero limits and nobody noticed until `kubectl top` showed
   ClickHouse at 6x its request).

4. **Sync-wave check**: if a new Application was added, confirm any CRD
   dependency it has on another Application in this repo is reflected in
   `argocd.argoproj.io/sync-wave` ordering (see README's "Sync waves"
   table) - and that the README table itself got updated to match.

Report findings plainly; this is meant to catch mistakes before push, not
to be a gate that blocks the user from proceeding if they've already
decided to.
