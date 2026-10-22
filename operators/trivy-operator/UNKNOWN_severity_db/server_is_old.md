That explains it directly. In **ClientServer mode**, having an **old Trivy Server** while using **`db:2`** and **Trivy Operator 0.34** is a textbook cause of all severities showing as `UNKNOWN`.

Here is the exact technical breakdown of what happens:

---

### 1. In ClientServer Mode, the Server Owns Severity Resolution
* In `ClientServer` mode, the scan pod / operator (client) only analyzes the image layers, collects the installed package list / OS metadata, and sends it over RPC (HTTP/Twirp) to the **Trivy Server**.
* **The Trivy Server is the only component that mounts `trivy-db`**, looks up the CVEs, calculates CVSS scores, and assigns severity ratings.
* If the server is old, whatever it returns is what the operator records in the `VulnerabilityReport` CRDs.

---

### 2. Old Server + `db:2` Schema Parsing Failure
* Aqua redesigned the internal BoltDB database schema when migrating to `ghcr.io/aquasecurity/trivy-db:2` (introducing separate buckets for NVD CVSS v3.1 vs vendor advisories, multi-vector scores, and new struct fields).
* When an **older Trivy Server binary** pulls `db:2`:
  - It can still read the package/CVE mapping bucket (so it successfully identifies the CVE IDs like `CVE-2023-45853`).
  - **However, it fails to deserialize the new severity/score struct** inside the database records.
  - In Go, failing to unmarshal an updated struct field silently leaves the struct field with its zero-value. In Trivy's codebase, the zero-value of the `Severity` enum is:
    ```go
    SeverityUnknown Severity = 0 // "UNKNOWN"
    ```
  - As a result, the server successfully finds the vulnerabilities, but sets every single severity to `UNKNOWN` and score to `0` or `null`.

---

### 3. RPC Protocol Drift (Client 0.34 vs Old Server)
* Trivy Operator 0.34 is relatively recent (ships with Trivy ~0.56–0.58).
* Across major Trivy releases, Aqua changed the Twirp/RPC payload contract between client and server for vulnerability findings (specifically how `primary_link`, `severity`, and `custom_severities` are represented in protobuf).
* If the server runs an older schema/proto definition, the client receives enum value `0` or misses the severity field during unmarshaling, defaulting to `UNKNOWN`.

---

### The Fix

Align the Trivy Server version with the Trivy Operator version:

1. **Check Operator 0.34's expected Trivy version**:
   Operator `0.34.x` corresponds to Trivy Server image `aquasec/trivy:0.56.2` (or `0.57.x`/`0.58.x`).
2. **Update the Trivy Server deployment**:
   ```yaml
   # In your trivy server deployment or helm values:
   image:
     repository: mirror.gcr.io/aquasec/trivy  # or aquasec/trivy
     tag: 0.58.2  # Match operator's bundled trivy version
   ```
3. **Wipe the old cached DB volume on the server**:
   When upgrading the server, purge the server's cache/PVC (or run `trivy server --clear-cache`) so it does a fresh pull and clean extraction of `ghcr.io/aquasecurity/trivy-db:2`.
4. **Trigger a re-scan**:
   Once the server restarts with the matching version, trigger a rescan by annotating or deleting a workload report; severities will immediately resolve to `CRITICAL`, `HIGH`, `MEDIUM`, etc.
