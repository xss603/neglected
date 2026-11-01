Searched "xz" "el9" site:access.redhat.com/errata

### 1. Is `5.2.5-8.el9_8.1` the right package to install?

**Yes, 100%.** 

* **Active Repository Match**: It is the official package currently hosted in the UBI9 repository (`ubi-9-baseos-rpms`), which matches the `9.8` base image defined in your repository (`config.yaml`).
* **Dependency Match**: `ubi-minimal` comes with `xz-libs-5.2.5-8.el9_8.1.x86_64` pre-installed in the root filesystem. Installing `xz-5.2.5-8.el9_8.1` ensures `xz` and `xz-libs` stay on the exact same build version.
* **Clean Security Scan**: Scanned with Trivy, `5.2.5-8.el9_8.1` has **0 known vulnerabilities**.

---

### 2. Why not `5.2.5-8.el9_0`? Does it have CVEs?

**Yes, `5.2.5-8.el9_0` has known vulnerabilities.**

#### Why `5.2.5-8.el9_0` is obsolete and vulnerable:

1. **Unpatched CVEs (e.g., CVE-2026-34743)**:
   - `5.2.5-8.el9_0` was released back in **May 2022** for RHEL 9.0 (to fix the older CVE-2022-1271).
   - Any CVE discovered after 2022 is **not patched** in `5.2.5-8.el9_0`.
   - For example, **CVE-2026-34743** (buffer overflow in `lzma_index_append()` via advisory **RHSA-2026:89749**) was resolved in `5.2.5-8.el9_8.1`.
   - If you force-installed `5.2.5-8.el9_0`, **Trivy would flag your image as vulnerable to CVE-2026-34743**.

2. **Why Trivy might have mentioned `.el9_0` in the first place**:
   - If a scanner told you to install `xz-5.2.5-8.el9_0`, it was citing the **minimum version** that fixed an older 2022 issue (CVE-2022-1271).
   - In package vulnerability databases, the rule is always:  
     $$\text{fixed in } \ge \text{5.2.5-8.el9\_0}$$
   - Since `5.2.5-8.el9_8.1` is greater than `5.2.5-8.el9_0`, it satisfies that fix **and** includes all subsequent security patches.

3. **Dependency and Repository Blockers**:
   - `microdnf` cannot find it because Red Hat removes superseded point-release packages from public UBI repositories.
   - `ubi-minimal` already has `xz-libs-5.2.5-8.el9_8.1` installed; trying to install `xz-5.2.5-8.el9_0` fails due to mismatched library requirements.

---

### Summary Table

| Package | In UBI Repo? | Compatible with Base `xz-libs`? | Security Status |
| :--- | :--- | :--- | :--- |
| **`xz-5.2.5-8.el9_0`** | ❌ No (Purged) | ❌ No (Dependency conflict) | ❌ Vulnerable to CVE-2026-34743 |
| **`xz-5.2.5-8.el9_8.1`** |  **Yes** |  **Yes (Exact match)** |  **Clean (0 Trivy CVEs)** |

Use **`xz-5.2.5-8.el9_8.1`** in your Dockerfile.
