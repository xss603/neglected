When Trivy Operator marks **all** vulnerabilities as `UNKNOWN` severity, it almost always points to an issue with **how Trivy acquires, parses, or correlates its vulnerability database (Trivy DB)**.

Here are the most common root causes and how to diagnose them:

---

### 1. Air-Gapped / Egress Blocked & Empty Trivy DB
* **What happens**: Trivy relies on downloading `ghcr.io/aquasecurity/trivy-db:2` at runtime or in an init container. If the cluster has egress firewalls, proxies, or NetworkPolicies blocking GitHub Container Registry (GHCR), Trivy cannot fetch or update the DB.
* **Result**: Trivy falls back to heuristic package detection or runs with an empty database. Findings without database correlation default to severity `UNKNOWN` and score `0` / `null`.
* **Fix**: Check scan job logs for `downloading vulnerability DB... failed`. If air-gapped, configure a private mirror in `trivy-operator-trivy-config`:
  ```yaml
  trivy:
    dbRepository: "<internal-registry>/aquasec/trivy-db"
    javaDbRepository: "<internal-registry>/aquasec/trivy-java-db"
  ```

---

### 2. Trivy Binary & Trivy DB Schema Incompatibility
* **What happens**: Aqua transitioned `trivy-db` from schema version `v1` to schema version `v2` (`ghcr.io/aquasecurity/trivy-db:2`).
* **Result**: If an older version of Trivy Operator (or a custom Trivy CLI image) pulls the modern v2 database (or conversely, a modern Trivy image pulls an old v1 cached mirror), Trivy can match CVE IDs by name but fails to deserialize the CVSS score / severity structs, causing **every single finding's severity to fall back to `UNKNOWN`**.
* **Fix**: Verify version compatibility between the Trivy image (`trivy.tag`) and `trivy.dbRepository`:
  - Trivy `>= 0.30+` requires `ghcr.io/aquasecurity/trivy-db:2`.

---

### 3. Missing or Read-Only DB Cache Directory
* **What happens**: In `Standalone` mode, Trivy scan pods use an `initContainer` to populate `/var/trivyoperator/trivy-db` (or `/tmp/trivy/.cache`).
* **Result**:
  - If the path specified in `trivy.filesystemScanCacheDir` differs from where the init container wrote the DB.
  - Or if `securityContext.readOnlyRootFilesystem: true` is set without mounting a writable `emptyDir` on the cache directory.
  - Trivy runs with an empty cache and cannot query severity levels.
* **Fix**: Check `kubectl get configmap trivy-operator-trivy-config -n trivy-system -o yaml`:
  ```yaml
  trivy.filesystemScanCacheDir: /var/trivyoperator/trivy-db
  trivy.imageScanCacheDir: /tmp/trivy/.cache
  ```
  Ensure scan pods have a corresponding `volumeMount` on that exact path.

---

### 4. Distro Detection Failure (Distroless / Scratch / Custom OS)
* **What happens**: Trivy queries OS-specific vulnerability trackers (Debian SecTracker, Ubuntu OVAL, Alpine SecDB, Red Hat CSAF/OVAL).
* **Result**:
  - For `FROM scratch`, distroless, or stripped custom containers lacking `/etc/os-release`, Trivy cannot identify the Linux distribution.
  - Without an identifiable OS release, distro-curated severities cannot be resolved, and if NVD has no vendor-specific score, Trivy records `UNKNOWN`.

---

### 5. Harbor Trivy Adapter Translation Bug
* **What happens**: If the reports were coming from Harbor via the Trivy Adapter rather than standalone Trivy Operator:
* **Result**: Several releases of the Harbor Trivy Adapter had a bug where CVSS v3 ratings from the new Aqua advisory API failed schema validation during JSON transformation, stripping the severity field and defaulting all items to `Unknown` in Harbor and downstream CRDs.
* **Fix**: Updating the Trivy adapter or enabling standalone Trivy Operator CRD reporting directly in the cluster bypasses this translation layer.

---

### Quick Diagnostic Steps for That Environment

1. **Check scan job pod logs**:
   ```bash
   kubectl logs -n trivy-system job/<scan-job-name> -c trivy
   ```
   Look for `DB error: failed to download vulnerability DB` or `failed to extract DB`.
2. **Inspect raw Trivy JSON output**:
   ```bash
   kubectl get vulnerabilityreports -n <namespace> <report-name> -o jsonpath='{.report.vulnerabilities[0]}'
   ```
   If `score` is missing and `primaryLink` is blank, Trivy operated without an intact `trivy-db`.
