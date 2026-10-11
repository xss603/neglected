# Sigstore & Cosign — Container Image Signing

Signs/verifies OCI images (and arbitrary blobs) so Kyverno can enforce
"only signed images run" cluster-wide. Does **not** touch git state by
itself — enforcement is a `ClusterPolicy` under `apps/kyverno-policies.yaml`.

## 1. Install (client, laptop/CI runner)

```bash
curl -O -L https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign
cosign version
```

## 2. Keyless signing (recommended — no private key to store/leak)

Uses Fulcio (short-lived cert via OIDC) + Rekor (public transparency log).
No secret ever touches this repo.

```bash
# interactive browser OIDC (GitHub/Google) — fine for local use
COSIGN_EXPERIMENTAL=1 cosign sign ghcr.io/<org>/<image>:<tag>

# CI (GitHub Actions) — uses the *workflow's own* OIDC token, no login prompt
cosign sign --yes ghcr.io/<org>/<image>:<tag>
```

GitHub Actions snippet (`.github/workflows/sign.yml`):

```yaml
permissions:
  id-token: write   # required for keyless OIDC
  contents: read
  packages: write
steps:
  - uses: sigstore/cosign-installer@v3
  - run: cosign sign --yes ${{ env.IMAGE }}@${{ steps.build.outputs.digest }}
```

Always sign by **digest**, not tag (tags are mutable).

## 3. Key-based signing (air-gapped / no OIDC)

```bash
cosign generate-key-pair                 # -> cosign.key / cosign.pub
# cosign.key NEVER goes in git. Store in Vault or CI secret store.
cosign sign --key cosign.key ghcr.io/<org>/<image>:<tag>
```

## 4. Verify

```bash
# keyless
cosign verify ghcr.io/<org>/<image>:<tag> \
  --certificate-identity-regexp '.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com

# key-based
cosign verify --key cosign.pub ghcr.io/<org>/<image>:<tag>
```

## 5. Enforce in-cluster (Kyverno)

Add a Kyverno `verifyImages` policy, synced in a wave **after** Kyverno's
own CRDs (see README "Sync waves" table). `failurePolicy` must be explicit
per this repo's known sharp edge:

```yaml
# manifests/kyverno-policies/verify-signed-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signatures
spec:
  validationFailureAction: Audit   # flip to Enforce once proven
  background: false
  failurePolicy: Ignore            # Audit-only -> must be Ignore, not default Fail
  rules:
    - name: check-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences: ["ghcr.io/<org>/*"]
          attestors:
            - entries:
                - keyless:
                    issuer: https://token.actions.githubusercontent.com
                    subject: "https://github.com/<org>/<repo>/.github/workflows/*"
```

Commit → push → `argocd app sync kyverno-policies` (hard-refresh per
CLAUDE.md verification loop) → check `kubectl get pod <new> -o yaml` for
no admission error, then flip `Audit` → `Enforce` only after a soak period.

## 6. Signing arbitrary blobs / attestations (SBOMs)

```bash
cosign attest --yes --predicate sbom.spdx.json --type spdxjson ghcr.io/<org>/<image>@<digest>
cosign verify-attestation --type spdxjson ghcr.io/<org>/<image>@<digest>
```

## Trade-offs

- **Keyless**: zero key management, but requires network to Fulcio/Rekor
  at sign *and* verify time — a problem for air-gapped verify.
- **Key-based**: works offline, but `cosign.key` is a secret you must
  rotate/protect (Vault, never git) — violates "no secrets in git" if
  mishandled.
- Start policies in `Audit` — `Enforce` with a misconfigured attestor on
  this single-replica admission controller can block *all* pod creation
  cluster-wide.
