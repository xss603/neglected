#!/usr/bin/env python3
"""
clone-app-repos.py

Discovers all unique Git repositories and target revisions referenced by ArgoCD
ApplicationSets and Applications, and clones/fetches them into a local target directory.

Capabilities:
- Discovers repos from live Kubernetes/ArgoCD resources (`kubectl`) or local configs (`--local-only`).
- Automatically extracts credentials for private repositories from ArgoCD repository Secrets
  (`argocd.argoproj.io/secret-type=repository`).
- Checks out or fetches the specified revisions (branches, tags, or commit hashes).
- Can skip already existing repos, or run `git fetch` and update them.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse, urlunparse


def run_cmd(cmd, cwd=None):
    try:
        res = subprocess.run(
            cmd,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True
        )
        return res.stdout.strip()
    except subprocess.CalledProcessError as e:
        return None


def get_argocd_repo_credentials(namespace="argocd"):
    """
    Looks up repository credentials from ArgoCD Secrets in the cluster.
    Returns a dict mapping clean repo URL -> dict(username=..., password=..., sshPrivateKey=...).
    """
    cmd = [
        "kubectl", "-n", namespace, "get", "secret",
        "-l", "argocd.argoproj.io/secret-type=repository",
        "-o", "json"
    ]
    out = run_cmd(cmd)
    creds = {}
    if not out:
        return creds

    try:
        data = json.loads(out)
        for item in data.get("items", []):
            sec_data = item.get("data", {})
            if "url" not in sec_data:
                continue

            raw_url = base64.b64decode(sec_data["url"]).decode("utf-8").strip()
            clean_url = clean_git_url(raw_url)

            cred_entry = {}
            if "username" in sec_data:
                cred_entry["username"] = base64.b64decode(sec_data["username"]).decode("utf-8").strip()
            if "password" in sec_data:
                cred_entry["password"] = base64.b64decode(sec_data["password"]).decode("utf-8").strip()
            if "sshPrivateKey" in sec_data:
                cred_entry["sshPrivateKey"] = base64.b64decode(sec_data["sshPrivateKey"]).decode("utf-8").strip()

            if cred_entry:
                creds[clean_url] = cred_entry
    except Exception as e:
        print(f"Warning: Could not fetch ArgoCD repo credentials: {e}", file=sys.stderr)

    return creds


def clean_git_url(repo_url):
    """Strips basic auth credentials and trailing slashes/.git from repository URLs."""
    if not repo_url or repo_url == "-":
        return "-"
    clean = re.sub(r"https?://[^@]+@", "https://", repo_url).rstrip("/")
    if clean.endswith(".git"):
        clean = clean[:-4]
    return clean


def repo_to_dir_name(repo_url):
    """Derives a friendly directory name from a Git repository URL."""
    clean = clean_git_url(repo_url)
    parts = [p for p in clean.split("/") if p and p not in ("http:", "https:", "ssh:")]
    if len(parts) >= 2:
        return f"{parts[-2]}_{parts[-1]}"
    elif parts:
        return parts[-1]
    return "repository"


def discover_live_repos(namespace="argocd"):
    """Discovers unique (repo_url, revision) pairs from live ArgoCD ApplicationSets and Applications."""
    cmd = ["kubectl", "-n", namespace, "get", "applicationsets,applications", "-o", "json"]
    out = run_cmd(cmd)
    if not out:
        return set()

    git_sources = set()
    try:
        data = json.loads(out)
        for item in data.get("items", []):
            kind = item.get("kind")
            spec = item.get("spec", {})

            if kind == "ApplicationSet":
                for gen in spec.get("generators", []):
                    if "git" in gen:
                        g = gen["git"]
                        repo = g.get("repoURL")
                        rev = g.get("revision", "HEAD")
                        if repo and not repo.endswith("/charts") and "helm" not in repo:
                            git_sources.add((repo, rev))

            elif kind == "Application":
                sources = spec.get("sources")
                source = spec.get("source")

                if sources:
                    for s in sources:
                        chart = s.get("chart")
                        repo = s.get("repoURL")
                        rev = s.get("targetRevision", "HEAD")
                        if repo and not chart:
                            git_sources.add((repo, rev))
                elif source:
                    chart = source.get("chart")
                    repo = source.get("repoURL")
                    rev = source.get("targetRevision", "HEAD")
                    if repo and not chart:
                        git_sources.add((repo, rev))
    except Exception as e:
        print(f"Warning: Failed to parse cluster resources: {e}", file=sys.stderr)

    return git_sources


def discover_local_repos(repo_root):
    """Discovers unique (repo_url, revision) pairs by reading local repo files."""
    git_sources = set()

    # 1. Check bootstrap root-app.yaml
    root_app = repo_root / "bootstrap" / "root-app.yaml"
    if root_app.exists():
        try:
            import yaml
            with open(root_app) as f:
                doc = yaml.safe_load(f)
            s = doc.get("spec", {}).get("source", {})
            repo = s.get("repoURL")
            rev = s.get("targetRevision", "HEAD")
            if repo and not s.get("chart"):
                git_sources.add((repo, rev))
        except Exception:
            pass

    # 2. Check applicationsets/*.yaml
    appsets_dir = repo_root / "applicationsets"
    if appsets_dir.exists():
        try:
            import yaml
            for f in appsets_dir.glob("*.yaml"):
                with open(f) as fp:
                    for doc in yaml.safe_load_all(fp):
                        if doc and doc.get("kind") == "ApplicationSet":
                            for gen in doc.get("spec", {}).get("generators", []):
                                if "git" in gen:
                                    g = gen["git"]
                                    repo = g.get("repoURL")
                                    rev = g.get("revision", "HEAD")
                                    if repo:
                                        git_sources.add((repo, rev))
        except Exception:
            pass

    # 3. Check apps/**/dir-appconfig.yaml
    apps_dir = repo_root / "apps"
    if apps_dir.exists():
        try:
            import yaml
            for f in apps_dir.rglob("dir-appconfig.yaml"):
                with open(f) as fp:
                    doc = yaml.safe_load(fp)
                    repo = doc.get("repoURL")
                    rev = doc.get("targetRevision", "HEAD")
                    if repo:
                        git_sources.add((repo, rev))
        except Exception:
            pass

    return git_sources


def attach_credentials(repo_url, creds):
    """Injects username:password if credentials exist for the repository URL."""
    clean = clean_git_url(repo_url)
    if clean in creds and "username" in creds[clean] and "password" in creds[clean]:
        u = creds[clean]["username"]
        p = creds[clean]["password"]
        parsed = urlparse(repo_url)
        netloc = f"{u}:{p}@{parsed.hostname}"
        if parsed.port:
            netloc += f":{parsed.port}"
        return urlunparse((parsed.scheme, netloc, parsed.path, parsed.params, parsed.query, parsed.fragment))
    return repo_url


def clone_or_update(repo_url, revision, target_dir, creds=None, update=False):
    """Clones repository or fetches latest changes if already existing."""
    clean = clean_git_url(repo_url)
    auth_url = attach_credentials(repo_url, creds) if creds else repo_url
    dest_path = target_dir / repo_to_dir_name(repo_url)

    if dest_path.exists() and (dest_path / ".git").exists():
        print(f"[*] Repository already exists at {dest_path}")
        if update:
            print(f"    Fetching updates for {clean} ({revision})...")
            run_cmd(["git", "fetch", "--all"], cwd=dest_path)
            if revision and revision != "HEAD":
                run_cmd(["git", "checkout", revision], cwd=dest_path)
        else:
            print(f"    Skipping clone (pass --update to fetch updates).")
        return dest_path

    print(f"[*] Cloning {clean} (revision: {revision}) -> {dest_path.name}/ ...")
    cmd = ["git", "clone"]
    if revision and revision != "HEAD":
        cmd += ["--branch", revision]
    cmd += [auth_url, str(dest_path)]

    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        # Fallback if --branch fails (e.g. revision is a commit SHA)
        fallback_cmd = ["git", "clone", auth_url, str(dest_path)]
        res_fallback = subprocess.run(fallback_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if res_fallback.returncode == 0 and revision and revision != "HEAD":
            run_cmd(["git", "checkout", revision], cwd=dest_path)
        else:
            print(f"    [!] Error cloning {clean}: {res.stderr.strip()}", file=sys.stderr)
            return None

    print(f"    [✓] Successfully cloned {dest_path.name}")
    return dest_path


def main():
    parser = argparse.ArgumentParser(description="Clone all Git repository sources used in ArgoCD ApplicationSets and Applications")
    parser.add_argument("--dest", "-d", default="repos", help="Target directory to store cloned repositories (default: ./repos)")
    parser.add_argument("--namespace", "-n", default="argocd", help="ArgoCD namespace for live cluster queries (default: argocd)")
    parser.add_argument("--local-only", action="store_true", help="Only parse local repository files without querying kubectl")
    parser.add_argument("--update", "-u", action="store_true", help="Fetch and update repositories if they already exist")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent.parent
    target_dir = Path(args.dest).resolve()
    target_dir.mkdir(parents=True, exist_ok=True)

    git_sources = set()
    creds = {}

    if not args.local_only:
        print(f"Querying cluster for ApplicationSets, Applications, and Repository Secrets in '{args.namespace}'...")
        git_sources = discover_live_repos(args.namespace)
        creds = get_argocd_repo_credentials(args.namespace)

    # Fallback or local scan
    if not git_sources:
        print("Discovering repository sources from local manifests...")
        git_sources = discover_local_repos(repo_root)

    # Also check current git origin for credentials if matching
    try:
        origin_url = run_cmd(["git", "remote", "get-url", "origin"], cwd=repo_root)
        if origin_url and "@" in origin_url:
            clean_origin = clean_git_url(origin_url)
            parsed = urlparse(origin_url)
            if parsed.username and parsed.password:
                creds.setdefault(clean_origin, {
                    "username": parsed.username,
                    "password": parsed.password
                })
    except Exception:
        pass

    if not git_sources:
        print("No Git repositories found to clone.", file=sys.stderr)
        sys.exit(0)

    print(f"\nDiscovered {len(git_sources)} distinct Git source(s):")
    for r, rev in sorted(git_sources):
        print(f" - {clean_git_url(r)} (target revision: {rev})")
    print(f"\nCloning into: {target_dir}\n")

    cloned_count = 0
    for r, rev in sorted(git_sources):
        dest = clone_or_update(r, rev, target_dir, creds=creds, update=args.update)
        if dest:
            cloned_count += 1

    print(f"\nDone! Successfully processed {cloned_count}/{len(git_sources)} repositories.")


if __name__ == "__main__":
    main()
