#!/usr/bin/env python3
# gitlab-clone-group.py
# Clones all repositories from GitLab group with progress tracking
import os
import sys
import subprocess
import requests
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed

# Configuration
GITLAB_URL = os.getenv("GITLAB_URL", "https://gitlab.com")
GITLAB_TOKEN = os.getenv("GITLAB_TOKEN")
CLONE_DIR = os.getenv("CLONE_DIR", "./gitlab-clones")
PARALLEL_JOBS = int(os.getenv("PARALLEL_JOBS", "4"))

# Colors
class Colors:
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    RED = '\033[0;31m'
    NC = '\033[0m'

def log(level, msg):
    color = {"INFO": Colors.GREEN, "WARN": Colors.YELLOW, "ERROR": Colors.RED}.get(level, "")
    print(f"{color}[{level}]{Colors.NC} {msg}", file=sys.stderr if level == "ERROR" else sys.stdout)

def fetch_all_projects(group_id):
    """Fetch all projects from group with pagination"""
    headers = {"PRIVATE-TOKEN": GITLAB_TOKEN}
    projects = []
    page = 1
    
    while True:
        log("INFO", f"Fetching page {page}...")
        url = f"{GITLAB_URL}/api/v4/groups/{group_id}/projects"
        params = {
            "per_page": 100,
            "page": page,
            "include_subgroups": "true",
            "archived": "false"
        }
        
        try:
            resp = requests.get(url, headers=headers, params=params, timeout=30)
            resp.raise_for_status()
        except requests.exceptions.RequestException as e:
            log("ERROR", f"API request failed: {e}")
            sys.exit(1)
        
        data = resp.json()
        if not data:
            break
        
        projects.extend(data)
        page += 1
    
    return projects

def clone_repo(repo):
    """Clone a single repository"""
    repo_url = repo["http_url_to_repo"]
    repo_path = os.path.join(CLONE_DIR, repo["path_with_namespace"])
    repo_name = repo["name"]
    
    # Check if already cloned
    if os.path.exists(repo_path):
        return {"name": repo_name, "status": "skipped", "message": "Already exists"}
    
    # Inject token for auth
    parsed = urlparse(repo_url)
    auth_url = f"{parsed.scheme}://oauth2:{GITLAB_TOKEN}@{parsed.netloc}{parsed.path}"
    
    # Create parent directory
    os.makedirs(os.path.dirname(repo_path), exist_ok=True)
    
    try:
        subprocess.run(
            ["git", "clone", "--quiet", auth_url, repo_path],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=300
        )
        
        # Remove token from git config
        subprocess.run(
            ["git", "-C", repo_path, "config", "--unset", "credential.helper"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
        
        return {"name": repo_name, "status": "success", "message": "Cloned"}
    
    except subprocess.TimeoutExpired:
        return {"name": repo_name, "status": "failed", "message": "Timeout"}
    except subprocess.CalledProcessError as e:
        error_msg = e.stderr.decode() if e.stderr else "Unknown error"
        return {"name": repo_name, "status": "failed", "message": error_msg}
    except Exception as e:
        return {"name": repo_name, "status": "failed", "message": str(e)}

def main():
    if not GITLAB_TOKEN:
        log("ERROR", "GITLAB_TOKEN environment variable not set")
        sys.exit(1)
    
    if len(sys.argv) < 2:
        log("ERROR", "Usage: python3 gitlab-clone-group.py <group-id-or-path>")
        sys.exit(1)
    
    group_id = sys.argv[1]
    
    # Create clone directory
    os.makedirs(CLONE_DIR, exist_ok=True)
    
    log("INFO", f"Fetching repositories from group: {group_id}")
    projects = fetch_all_projects(group_id)
    
    if not projects:
        log("ERROR", f"No repositories found in group {group_id}")
        sys.exit(1)
    
    total = len(projects)
    log("INFO", f"Found {total} repositories")
    
    # Clone in parallel
    results = {"success": 0, "failed": 0, "skipped": 0}
    
    with ThreadPoolExecutor(max_workers=PARALLEL_JOBS) as executor:
        futures = {executor.submit(clone_repo, repo): repo for repo in projects}
        
        for future in as_completed(futures):
            result = future.result()
            status = result["status"]
            results[status] += 1
            
            if status == "success":
                log("INFO", f"✓ [{results['success']}/{total}] {result['name']}")
            elif status == "failed":
                log("ERROR", f"✗ {result['name']}: {result['message']}")
            else:
                log("WARN", f"⊘ {result['name']}: {result['message']}")
    
    # Summary
    log("INFO", f"Clone completed: {os.path.abspath(CLONE_DIR)}")
    log("INFO", f"Success: {results['success']}, Failed: {results['failed']}, Skipped: {results['skipped']}")
    
    if results["failed"] > 0:
        sys.exit(1)

if __name__ == "__main__":
    main()
