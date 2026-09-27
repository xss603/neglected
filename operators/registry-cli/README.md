# Registry CLIs: JFrog CLI (`jf`) and IBM Cloud CR (`ibmcloud cr`)

Reference for managing container images across both registries this org
uses: JFrog Artifactory (image storage + Xray scanning) and IBM Cloud
Container Registry (`fr2.icr.io`, the mirror already used by
`operators/trivy-operator`'s Helm dependency). **No credentials in this
repo** — every command below reads auth from env vars / an external
credential store (Vault, IBM Cloud IAM API key), never a literal token
committed to git.

---

## JFrog CLI (`jf`)

### Install

```bash
curl -fL https://install-cli.jfrog.io | sh
jf --version
```

### Auth (no secrets in git)

```bash
# interactive one-time config, stored in ~/.jfrog (outside this repo)
jf config add mycompany \
  --artifactory-url=https://mycompany.jfrog.io/artifactory \
  --user="$JFROG_USER" \
  --access-token="$JFROG_ACCESS_TOKEN"   # from Vault/CI secret, never hardcoded
jf config use mycompany
```

### Image operations

```bash
# docker login via jf (writes to docker's own credential store, not this repo)
jf docker-login mycompany-docker-local

# push / pull with build-info collection
jf docker push mycompany.jfrog.io/docker-local/myapp:1.2.3 --build-name=myapp --build-number=1.2.3
jf docker pull mycompany.jfrog.io/docker-local/myapp:1.2.3

# list / search tags for an image
jf rt search "docker-local/myapp/*"

# copy / move / delete an artifact (image manifest path in the repo)
jf rt copy  docker-local/myapp/1.2.3/ docker-local-staging/myapp/1.2.3/
jf rt move  docker-local/myapp/1.2.3/ docker-local-release/myapp/1.2.3/
jf rt delete docker-local/myapp/1.2.3/ --quiet

# promote a CI build across repos (staging -> release) without re-pushing
jf rt build-promote myapp 1.2.3 docker-local-release

# Xray vulnerability scan (fits the "DAST/SAST/IaC scanning" posture)
jf xr scan docker-local/myapp/1.2.3/
```

### Retention / cleanup

```bash
# find images older than N days (search + jq, since jf has no built-in TTL delete)
jf rt search "docker-local/myapp/*" \
  | jq -r '.[] | select(.modified < (now - 30*86400 | strftime("%Y-%m-%dT%H:%M:%S"))) | .path' \
  | xargs -r -n1 jf rt delete --quiet
```

---

## IBM Cloud Container Registry (`ibmcloud cr`)

This is what backs `fr2.icr.io` — the same OCI registry `operators/trivy-operator`'s
wrapper `Chart.yaml` pulls from (`oci://fr2.icr.io/<account-namespace>/toolbox/helm`).

### Install

```bash
curl -fsSL https://clis.cloud.ibm.com/install/linux | sh
ibmcloud plugin install container-registry -f
ibmcloud plugin install vulnerability-advisor -f   # optional, for `ibmcloud cr va`
```

### Auth and region (no secrets in git)

```bash
# API key from Vault/CI secret - never hardcoded
ibmcloud login --apikey "$IBMCLOUD_API_KEY" -r eu-de
ibmcloud target -g <resource-group>
ibmcloud cr region-set fr2          # matches fr2.icr.io
ibmcloud cr login                   # wires docker (and helm registry) auth locally
```

### Namespace management

```bash
ibmcloud cr namespace-list
ibmcloud cr namespace-add <account-namespace>
ibmcloud cr namespace-rm <account-namespace>    # destructive - confirm nothing references it first
```

### Image operations

```bash
# list images in a namespace
ibmcloud cr image-list --restrict <account-namespace>

# inspect one image (digest, size, layers, created)
ibmcloud cr image-inspect fr2.icr.io/<account-namespace>/toolbox/myimage:1.2.3

# list all digests/tags for a repo
ibmcloud cr image-digests --restrict <account-namespace>/toolbox/myimage

# tag (creates a new tag pointing at the same digest, no re-push)
ibmcloud cr image-tag \
  fr2.icr.io/<account-namespace>/toolbox/myimage:1.2.3 \
  fr2.icr.io/<account-namespace>/toolbox/myimage:stable

# remove an image (single tag) or a whole digest
ibmcloud cr image-rm fr2.icr.io/<account-namespace>/toolbox/myimage:old-tag
```

### Vulnerability scanning

```bash
ibmcloud cr va fr2.icr.io/<account-namespace>/toolbox/myimage:1.2.3
```

### Retention policy (built-in TTL, no cron/jq needed)

```bash
ibmcloud cr retention-policy-set <account-namespace> --images 5 --days 30
ibmcloud cr retention-policy-get <account-namespace>
```

### Building directly in the registry (no local docker needed)

```bash
ibmcloud cr build -t fr2.icr.io/<account-namespace>/toolbox/myimage:1.2.3 .
```

---

## Helm OCI pulls from `fr2.icr.io` (ties back to `operators/trivy-operator`)

`ibmcloud cr login` also authorizes `helm registry login` against the same
host, so once logged in you can run the `helm show chart` / `helm pull`
commands documented in `operators/trivy-operator/README.md` without a
separate auth step:

```bash
ibmcloud cr login
helm show chart oci://fr2.icr.io/<account-namespace>/toolbox/helm/trivy-operator --version 0.36.0
```

## Caveats

- Both CLIs write credentials to local config (`~/.jfrog`, `~/.bluemix` /
  docker's own credential store) — never to this repo. If a script here
  needs a token, it reads an env var, it does not embed one.
- `ibmcloud cr image-rm` / `namespace-rm` are irreversible - confirm nothing
  (a running Deployment, a pinned Helm dependency `version:`) still
  references the digest/tag/namespace before removing it.
- `jf rt delete` / `move` mutate Artifactory paths directly — prefer
  `build-promote` over manual `copy`/`move` when a CI build produced the
  artifact, so build-info stays consistent.
- Rate limits: both registries throttle anonymous/unauthenticated pulls;
  always `docker login`/`ibmcloud cr login`/`jf docker-login` before bulk
  operations, same rationale as the `mirror.gcr.io` note in
  `operators/trivy-operator/values-fix.yaml`.
