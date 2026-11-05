#!/usr/bin/env python3
"""
generate-apps-inventory.py

Lists all ArgoCD ApplicationSets and Applications, extracts their Git repository
sources, chart repositories, paths, target versions/revisions, and Ingress URLs,
and generates a Markdown table inventory with clickable Git/Path and Ingress links.

Can query live Kubernetes cluster via `kubectl` or parse local git repository files
(`apps/`, `applicationsets/`, `bootstrap/`).
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


def run_cmd(cmd):
    try:
        res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
        return res.stdout
    except Exception:
        return None


def clean_git_url(repo_url):
    """Strip token credentials and trailing .git from repo URLs."""
    if not repo_url or repo_url == "-":
        return "-"
    clean = re.sub(r"https?://[^@]+@", "https://", repo_url).rstrip("/")
    if clean.endswith(".git"):
        clean = clean[:-4]
    return clean


def format_git_link(repo_url, revision, path):
    """Creates a markdown clickable link for Git Repo + Path."""
    if not path or path == "-":
        if not repo_url or repo_url == "-":
            return "-"
        clean_repo = clean_git_url(repo_url)
        return f"[{repo_url}]({clean_repo})"

    if not repo_url or repo_url == "-":
        return f"`{path}`"

    clean_repo = clean_git_url(repo_url)
    rev = revision if revision and revision != "-" else "HEAD"
    clean_path = path.lstrip("/")

    if "gitlab" in clean_repo.lower():
        link = f"{clean_repo}/-/tree/{rev}/{clean_path}"
    elif "github" in clean_repo.lower():
        link = f"{clean_repo}/tree/{rev}/{clean_path}"
    else:
        link = f"{clean_repo}/{clean_path}"

    return f"[{clean_path}]({link})"


def get_live_ingresses():
    """Returns a dict mapping application_name -> list of URL strings."""
    cmd = ["kubectl", "get", "ingress", "-A", "-o", "json"]
    out = run_cmd(cmd)
    if not out:
        return {}
    
    app_ingresses = {}
    try:
        data = json.loads(out)
        for ing in data.get("items", []):
            meta = ing.get("metadata", {})
            tracking = meta.get("annotations", {}).get("argocd.argoproj.io/tracking-id")
            app_name = None
            if tracking:
                app_name = tracking.split(":")[0]
            if not app_name:
                app_name = meta.get("labels", {}).get("app.kubernetes.io/instance")

            spec = ing.get("spec", {})
            rules = spec.get("rules", [])
            tls_list = spec.get("tls", [])
            tls_hosts = set()
            for t in tls_list:
                for h in t.get("hosts", []):
                    tls_hosts.add(h)

            for r in rules:
                host = r.get("host")
                if host:
                    scheme = "https" if host in tls_hosts else "http"
                    url = f"{scheme}://{host}"
                    if app_name:
                        app_ingresses.setdefault(app_name, [])
                        if url not in app_ingresses[app_name]:
                            app_ingresses[app_name].append(url)
    except Exception as e:
        print(f"Warning: Failed to parse ingresses: {e}", file=sys.stderr)

    return app_ingresses


def get_live_resources(namespace="argocd"):
    cmd = ["kubectl", "-n", namespace, "get", "applicationsets,applications", "-o", "json"]
    out = run_cmd(cmd)
    if not out:
        return []
    try:
        data = json.loads(out)
        return data.get("items", [])
    except Exception as e:
        print(f"Warning: Failed to parse kubectl JSON output: {e}", file=sys.stderr)
        return []


def parse_live_resources(items, live_ingresses=None):
    if live_ingresses is None:
        live_ingresses = {}

    appsets = []
    apps = []

    for item in items:
        kind = item.get("kind")
        metadata = item.get("metadata", {})
        spec = item.get("spec", {})
        name = metadata.get("name")

        if kind == "ApplicationSet":
            generators = spec.get("generators", [])
            for gen in generators:
                if "git" in gen:
                    g = gen["git"]
                    repo = g.get("repoURL", "-")
                    rev = g.get("revision", "HEAD")
                    paths = []
                    for f in g.get("files", []):
                        paths.append(f.get("path"))
                    for d in g.get("directories", []):
                        paths.append(d.get("path"))
                    path_str = ", ".join(paths) if paths else "-"
                    appsets.append({
                        "name": name,
                        "repo": repo,
                        "revision": rev,
                        "path": path_str,
                        "generator": "git"
                    })
                elif "matrix" in gen or "list" in gen or "cluster" in gen:
                    appsets.append({
                        "name": name,
                        "repo": "-",
                        "revision": "-",
                        "path": "-",
                        "generator": list(gen.keys())[0]
                    })

        elif kind == "Application":
            sources = spec.get("sources")
            source = spec.get("source")
            
            git_repo = None
            git_path = None
            git_revision = None
            chart = None
            chart_repo = None
            version = None

            if sources:
                for s in sources:
                    if s.get("chart"):
                        chart = s.get("chart")
                        chart_repo = s.get("repoURL")
                        version = s.get("targetRevision")
                    if s.get("helm", {}).get("valueFiles"):
                        for vf in s["helm"]["valueFiles"]:
                            clean_vf = vf.replace("$values/", "")
                            git_path = os.path.dirname(clean_vf)
                    if s.get("repoURL") and not s.get("chart"):
                        git_repo = s.get("repoURL")
                        git_revision = s.get("targetRevision")
                    if s.get("path"):
                        git_path = s.get("path")
                        if not git_repo and s.get("repoURL"):
                            git_repo = s.get("repoURL")
                            git_revision = s.get("targetRevision")
                
                # Fallback if git_repo was not set
                if not git_repo:
                    git_repo = chart_repo
                    git_revision = version

            elif source:
                chart = source.get("chart")
                if chart:
                    chart_repo = source.get("repoURL")
                    version = source.get("targetRevision")
                else:
                    git_repo = source.get("repoURL")
                    git_path = source.get("path")
                    git_revision = source.get("targetRevision")
                    version = source.get("targetRevision")

            ingresses = live_ingresses.get(name, [])

            apps.append({
                "name": name,
                "chart": chart or "-",
                "version": version or "-",
                "git_repo": git_repo or "-",
                "git_revision": git_revision or version or "-",
                "chart_repo": chart_repo or "-",
                "path": git_path or "-",
                "ingresses": ingresses
            })

    return appsets, apps


def extract_ingresses_from_values(values_path):
    """Scans a values.yaml file for ingress hosts/hostnames."""
    urls = []
    if not values_path.exists():
        return urls
    try:
        import yaml
        with open(values_path) as f:
            docs = yaml.safe_load_all(f)
            for data in docs:
                if not isinstance(data, dict):
                    continue

                def find_hosts(obj):
                    if isinstance(obj, dict):
                        if "host" in obj and isinstance(obj["host"], str) and "." in obj["host"]:
                            urls.append(f"https://{obj['host']}")
                        if "hosts" in obj and isinstance(obj["hosts"], list):
                            for h in obj["hosts"]:
                                if isinstance(h, str) and "." in h:
                                    urls.append(f"https://{h}")
                                elif isinstance(h, dict) and "host" in h:
                                    urls.append(f"https://{h['host']}")
                        for k, v in obj.items():
                            find_hosts(v)
                    elif isinstance(obj, list):
                        for item in obj:
                            find_hosts(item)

                find_hosts(data)
    except Exception:
        pass
    return sorted(list(set(urls)))


def parse_local_repo(repo_root):
    appsets = []
    apps = []

    # Parse local appconfig.yaml & dir-appconfig.yaml files
    apps_dir = repo_root / "apps"
    if apps_dir.exists():
        for conf_file in apps_dir.rglob("*appconfig.yaml"):
            try:
                import yaml
                with open(conf_file) as f:
                    doc = yaml.safe_load(f)
                if not doc:
                    continue
                rel_path = conf_file.parent.relative_to(repo_root)
                name = conf_file.parent.name
                
                chart = doc.get("chart", "-")
                version = doc.get("targetRevision", "-")
                chart_repo = doc.get("repoURL", "-")
                git_path = doc.get("sourcePath", str(rel_path))
                
                # Check for values.yaml in same directory
                values_file = conf_file.parent / "values.yaml"
                ingresses = extract_ingresses_from_values(values_file)

                apps.append({
                    "name": name,
                    "chart": chart if chart else "-",
                    "version": str(version),
                    "git_repo": "https://gitlab.com/ayoubelmaaradi/devsecops.git",
                    "git_revision": "devops-lab",
                    "chart_repo": chart_repo if chart else "-",
                    "path": git_path,
                    "ingresses": ingresses
                })
            except Exception:
                pass

    # Check root-app.yaml
    root_app = repo_root / "bootstrap" / "root-app.yaml"
    if root_app.exists():
        try:
            import yaml
            with open(root_app) as f:
                doc = yaml.safe_load(f)
            if doc and doc.get("kind") == "Application":
                s = doc.get("spec", {}).get("source", {})
                apps.append({
                    "name": doc.get("metadata", {}).get("name", "root"),
                    "chart": "-",
                    "version": str(s.get("targetRevision", "-")),
                    "git_repo": s.get("repoURL", "-"),
                    "git_revision": str(s.get("targetRevision", "-")),
                    "chart_repo": "-",
                    "path": s.get("path", "-"),
                    "ingresses": []
                })
        except Exception:
            pass

    # Check ApplicationSets
    appsets_dir = repo_root / "applicationsets"
    if appsets_dir.exists():
        for as_file in appsets_dir.glob("*.yaml"):
            try:
                import yaml
                with open(as_file) as f:
                    docs = yaml.safe_load_all(f)
                    for doc in docs:
                        if doc and doc.get("kind") == "ApplicationSet":
                            name = doc.get("metadata", {}).get("name")
                            for gen in doc.get("spec", {}).get("generators", []):
                                if "git" in gen:
                                    g = gen["git"]
                                    paths = [f.get("path") for f in g.get("files", [])]
                                    appsets.append({
                                        "name": name,
                                        "repo": g.get("repoURL", "-"),
                                        "revision": g.get("revision", "HEAD"),
                                        "path": ", ".join(paths) if paths else "-",
                                        "generator": "git"
                                    })
            except Exception:
                pass

    return appsets, apps


def generate_markdown(appsets, apps):
    lines = []
    lines.append("# ArgoCD Inventory: ApplicationSets & Applications\n")
    lines.append("Generated inventory of all deployed ApplicationSets, Applications, their Git repository sources, chart sources, target paths, and exposed Ingress endpoints.\n")

    # ApplicationSets table
    lines.append("## ApplicationSets\n")
    lines.append("| ApplicationSet | Generator | Git Revision | Git Repo / Path Pattern |")
    lines.append("|---|---|---|---|")
    for aset in sorted(appsets, key=lambda x: x["name"]):
        path_patterns = [p.strip() for p in aset['path'].split(",")]
        links = []
        for p in path_patterns:
            links.append(format_git_link(aset['repo'], aset['revision'], p))
        links_str = "<br>".join(links)
        lines.append(f"| `{aset['name']}` | {aset['generator']} | `{aset['revision']}` | {links_str} |")
    lines.append("")

    # Applications table
    lines.append("## Applications\n")
    lines.append("| Application | Version | Chart | Git Repo + Path (Source) | Ingresses |")
    lines.append("|---|---|---|---|---|")
    for app in sorted(apps, key=lambda x: x["name"]):
        git_link = format_git_link(app['git_repo'], app['git_revision'], app['path'])
        chart_display = f"`{app['chart']}`" if app['chart'] != "-" else "-"
        
        ing_links = []
        for u in app.get("ingresses", []):
            ing_links.append(f"[{u}]({u})")
        ing_display = "<br>".join(ing_links) if ing_links else "-"

        lines.append(f"| `{app['name']}` | `{app['version']}` | {chart_display} | {git_link} | {ing_display} |")
    lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Generate Markdown inventory of ArgoCD ApplicationSets and Applications")
    parser.add_argument("--output", "-o", default="APPLICATIONS.md", help="Output markdown file (default: APPLICATIONS.md)")
    parser.add_argument("--namespace", "-n", default="argocd", help="ArgoCD namespace for live queries (default: argocd)")
    parser.add_argument("--local-only", action="store_true", help="Only parse local repository files without invoking kubectl")
    args = parser.parse_args()

    appsets = []
    apps = []

    repo_root = Path(__file__).resolve().parent.parent.parent

    # Try live query first if not local-only
    if not args.local_only:
        live_ingresses = get_live_ingresses()
        items = get_live_resources(args.namespace)
        if items:
            appsets, apps = parse_live_resources(items, live_ingresses)

    # Fallback to local files if live query yielded nothing or was skipped
    if not apps:
        print("Querying local repository manifests...", file=sys.stderr)
        appsets, apps = parse_local_repo(repo_root)

    if not apps and not appsets:
        print("Error: No Applications or ApplicationSets found.", file=sys.stderr)
        sys.exit(1)

    md_content = generate_markdown(appsets, apps)

    output_path = Path(args.output)
    output_path.write_text(md_content)
    print(f"Inventory successfully generated and written to {output_path.resolve()}")
    print(f"Total ApplicationSets: {len(appsets)}")
    print(f"Total Applications: {len(apps)}")


if __name__ == "__main__":
    main()
