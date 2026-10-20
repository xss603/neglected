#!/usr/bin/env python3
"""Join Trivy VulnerabilityReports to their scanned workload's live Pod
annotations and write one CSV row per vulnerability finding.

Inputs are plain `kubectl get ... -o json` dumps:
  - vulnerabilityreports.json: `kubectl get vulnerabilityreports.aquasecurity.github.io --all-namespaces -o json`
  - pods.json:                 `kubectl get pods --all-namespaces -o json`

Usage:
  python3 trivy_vulnerabilities_to_csv.py vulnerabilityreports.json pods.json out.csv
"""
import argparse
import csv
import json

FIELDNAMES = [
    "namespace", "resource_kind", "resource_name", "container",
    "image_repository", "image_tag", "severity", "vulnerability_id",
    "title", "installed_version", "fixed_version", "primary_link",
    "pod_annotations_json",
]


def build_pod_index(pods_data):
    """Map (owner_kind, namespace, owner_name) -> that pod's live annotations.

    trivy-operator's "resource.kind"/"resource.name" labels on a
    VulnerabilityReport name the Pod's immediate owner (e.g. ReplicaSet
    for a Deployment, Job for a CronJob) - which is exactly what a Pod's
    own ownerReferences[0] points at. Confirmed directly against a real
    cluster: a ReplicaSet-owned pod's ownerReferences (kind=ReplicaSet,
    name=<rs-name>) matches its VulnerabilityReport's labels exactly, so
    no extra hop is needed. Bare Pod scans are indexed by the Pod's own
    name under kind "Pod".

    Only the FIRST matching pod's annotations are kept per key - replicas
    of the same owner share a template in practice, so this is a
    reasonable best-effort join, not a guaranteed-unique one.
    """
    index = {}
    for pod in pods_data.get("items", []):
        meta = pod.get("metadata", {})
        ns = meta.get("namespace", "")
        name = meta.get("name", "")
        annotations = meta.get("annotations", {}) or {}
        index.setdefault(("Pod", ns, name), annotations)
        for owner in meta.get("ownerReferences", []) or []:
            key = (owner.get("kind", ""), ns, owner.get("name", ""))
            index.setdefault(key, annotations)
    return index


def pod_annotations_for(index, ns, kind, name):
    return index.get((kind, ns, name), {})


def write_csv(out_path, reports, pod_index):
    rows_written = 0
    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
        writer.writeheader()
        for item in reports:
            meta = item.get("metadata", {})
            labels = meta.get("labels", {}) or {}
            ns = labels.get("trivy-operator.resource.namespace", meta.get("namespace", ""))
            kind = labels.get("trivy-operator.resource.kind", "")
            name = labels.get("trivy-operator.resource.name", meta.get("name", ""))
            container = labels.get("trivy-operator.container.name", "")
            annotations = pod_annotations_for(pod_index, ns, kind, name)

            report = item.get("report", {})
            artifact = report.get("artifact", {})
            for v in report.get("vulnerabilities", []) or []:
                writer.writerow({
                    "namespace": ns,
                    "resource_kind": kind,
                    "resource_name": name,
                    "container": container,
                    "image_repository": artifact.get("repository", ""),
                    "image_tag": artifact.get("tag", artifact.get("digest", "")),
                    "severity": v.get("severity", "UNKNOWN"),
                    "vulnerability_id": v.get("vulnerabilityID", ""),
                    "title": v.get("title", ""),
                    "installed_version": v.get("installedVersion", ""),
                    "fixed_version": v.get("fixedVersion", ""),
                    "primary_link": v.get("primaryLink", ""),
                    "pod_annotations_json": json.dumps(annotations, sort_keys=True),
                })
                rows_written += 1
    return rows_written


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vulnerabilityreports_json", help="kubectl get vulnerabilityreports.aquasecurity.github.io -A -o json")
    parser.add_argument("pods_json", help="kubectl get pods -A -o json")
    parser.add_argument("out_csv", help="output CSV path")
    args = parser.parse_args()

    with open(args.vulnerabilityreports_json) as f:
        reports = json.load(f).get("items", [])
    with open(args.pods_json) as f:
        pods_data = json.load(f)

    pod_index = build_pod_index(pods_data)
    rows = write_csv(args.out_csv, reports, pod_index)
    print(f"wrote {rows} vulnerability rows from {len(reports)} reports to {args.out_csv}")


if __name__ == "__main__":
    main()
