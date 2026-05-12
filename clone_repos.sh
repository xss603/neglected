#!/usr/bin/env bash
# gitlab-clone-group.sh
# Clones all repositories from a GitLab group using Personal Access Token
set -euo pipefail

# Configuration
GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
GITLAB_TOKEN="${GITLAB_TOKEN:?ERROR: GITLAB_TOKEN not set}"
GROUP_ID="${1:?Usage: $0 <group-id-or-path>}"
CLONE_DIR="${CLONE_DIR:-./gitlab-clones}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Validate dependencies
for cmd in curl jq git; do
  command -v "$cmd" >/dev/null 2>&1 || { log_error "$cmd not found. Install: apt install $cmd"; exit 1; }
done

# Create clone directory
mkdir -p "$CLONE_DIR"
cd "$CLONE_DIR"

log_info "Fetching repositories from group: $GROUP_ID"

# Fetch all projects from group (handles pagination)
fetch_projects() {
  local page=1
  local per_page=100
  local all_projects="[]"
  
  while true; do
    log_info "Fetching page $page..."
    
    response=$(curl -fsSL \
      -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
      "${GITLAB_URL}/api/v4/groups/${GROUP_ID}/projects?per_page=${per_page}&page=${page}&include_subgroups=true&archived=false" \
      2>/dev/null) || {
      log_error "API call failed. Check GITLAB_TOKEN and GROUP_ID"
      exit 1
    }
    
    # Check if empty page (end of pagination)
    if [[ $(echo "$response" | jq '. | length') -eq 0 ]]; then
      break
    fi
    
    all_projects=$(echo "$all_projects" | jq -s ".[0] + $(echo "$response" | jq -c '.')")
    ((page++))
  done
  
  echo "$all_projects"
}

projects=$(fetch_projects)
total=$(echo "$projects" | jq '. | length')

if [[ $total -eq 0 ]]; then
  log_error "No repositories found in group $GROUP_ID"
  exit 1
fi

log_info "Found $total repositories"

# Clone function
clone_repo() {
  local repo_url="$1"
  local repo_path="$2"
  local repo_name="$3"
  
  # Inject token into URL for authentication
  local auth_url="${repo_url/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"
  
  if [[ -d "$repo_path" ]]; then
    log_warn "Skipping $repo_name (already exists)"
    return 0
  fi
  
  log_info "Cloning $repo_name..."
  
  if git clone --quiet "$auth_url" "$repo_path" 2>/dev/null; then
    # Remove token from .git/config for security
    git -C "$repo_path" config --unset credential.helper 2>/dev/null || true
    log_info "✓ Cloned: $repo_name"
  else
    log_error "✗ Failed: $repo_name"
    return 1
  fi
}

export -f clone_repo log_info log_warn log_error
export GITLAB_TOKEN RED GREEN YELLOW NC

# Extract repo info and clone in parallel
echo "$projects" | jq -r '.[] | "\(.http_url_to_repo)|\(.path_with_namespace)|\(.name)"' | \
  xargs -P "$PARALLEL_JOBS" -I {} bash -c '
    IFS="|" read -r url path name <<< "{}"
    clone_repo "$url" "$path" "$name"
  '

log_info "Clone completed: $PWD"
log_info "Total repositories: $total"

# Summary
success=$(find . -type d -name ".git" | wc -l)
log_info "Successfully cloned: $success/$total"

if [[ $success -lt $total ]]; then
  log_warn "Some repositories failed. Check errors above."
  exit 1
fi
