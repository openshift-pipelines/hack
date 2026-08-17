#!/usr/bin/env bash
#
# cleanup-branches.sh — Cleans up stale branches in a GitHub repository.
#
# 1. Deletes branches containing "konflux" (case-insensitive), skipping any
#    that have open pull requests.
# 2. Renames old release-v* branches by prefixing them with "obsolete-"
#    (e.g. release-v1.14.x → obsolete-release-v1.14.x). The following are
#    excluded from renaming:
#      - release-v1.15.x
#      - release-v1.20.x and above (minor version >= 20)
#
# Usage:
#   ./hack/cleanup-branches.sh <owner/repo> [--dry-run]
#
# Examples:
#   ./hack/cleanup-branches.sh openshift-pipelines/tektoncd-cli --dry-run
#   ./hack/cleanup-branches.sh openshift-pipelines/tektoncd-cli
#
# Requirements:
#   - gh CLI, authenticated with repo permissions (or GH_TOKEN set)
#
set -euo pipefail

REPO="${1:?Usage: $0 <owner/repo> [--dry-run]}"
DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

log()  { printf "[INFO]  %s\n" "$*"; }
warn() { printf "[WARN]  %s\n" "$*"; }
skip() { printf "[SKIP]  %s\n" "$*"; }
act()  { printf "[%s]  %s\n" "$($DRY_RUN && echo "DRY-RUN" || echo "ACTION")" "$*"; }

# URL-encode slashes in branch names for GitHub API ref paths
encode_ref() { echo "$1" | sed 's|/|%2F|g'; }

EXCLUDE_RELEASE_BRANCHES="release-v1.15.x"
MIN_KEEP_MINOR=20

should_keep_release_branch() {
  local branch="$1"
  [[ "$branch" == "$EXCLUDE_RELEASE_BRANCHES" ]] && return 0

  if [[ "$branch" =~ ^release-v([0-9]+)\.([0-9]+)\. ]]; then
    local minor="${BASH_REMATCH[2]}"
    (( minor >= MIN_KEEP_MINOR )) && return 0
  fi

  return 1
}

# --- Part 1: Delete branches containing "konflux" with no open PRs ---
delete_konflux_branches() {
  log "=== Deleting branches containing 'konflux' with no open PRs ==="

  local branches
  branches=$(gh api --paginate "repos/${REPO}/branches" -q '.[].name' | grep -i "konflux" || true)

  if [[ -z "$branches" ]]; then
    log "No branches containing 'konflux' found."
    return
  fi

  local total deleted skipped
  total=$(echo "$branches" | wc -l | tr -d ' ')
  deleted=0
  skipped=0

  while IFS= read -r branch; do
    local open_prs
    open_prs=$(gh pr list --repo "$REPO" --head "$branch" --state open --json number -q 'length')

    if (( open_prs > 0 )); then
      skip "$branch — has $open_prs open PR(s)"
      (( skipped++ ))
      continue
    fi

    act "Deleting branch: $branch"
    if ! $DRY_RUN; then
      gh api --method DELETE "repos/${REPO}/git/refs/heads/$(encode_ref "$branch")" --silent
    fi
    (( deleted++ ))
  done <<< "$branches"

  log "Konflux branches — total: $total, deleted: $deleted, skipped (has open PRs): $skipped"
}

# --- Part 2: Rename old release-v* branches to obsolete-release-v* ---
rename_old_release_branches() {
  log "=== Renaming old release-v* branches to obsolete-release-v* ==="

  local branches
  branches=$(gh api --paginate "repos/${REPO}/branches" -q '.[].name' | grep -E '^release-v' || true)

  if [[ -z "$branches" ]]; then
    log "No release-v* branches found."
    return
  fi

  local total renamed skipped
  total=$(echo "$branches" | wc -l | tr -d ' ')
  renamed=0
  skipped=0

  while IFS= read -r branch; do
    if should_keep_release_branch "$branch"; then
      skip "$branch — excluded from renaming"
      (( skipped++ ))
      continue
    fi

    local new_name="obsolete-${branch}"

    # Skip if target already exists (e.g. from a previous partial run)
    if gh api "repos/${REPO}/git/refs/heads/$(encode_ref "$new_name")" --silent 2>/dev/null; then
      skip "$branch — target '${new_name}' already exists"
      (( skipped++ ))
      continue
    fi

    act "Renaming: $branch -> $new_name"
    if ! $DRY_RUN; then
      gh api --method POST "repos/${REPO}/git/refs" \
        -f "ref=refs/heads/${new_name}" \
        -f "sha=$(gh api "repos/${REPO}/git/refs/heads/$(encode_ref "$branch")" -q '.object.sha')" --silent
      gh api --method DELETE "repos/${REPO}/git/refs/heads/$(encode_ref "$branch")" --silent
    fi
    (( renamed++ ))
  done <<< "$branches"

  log "Release branches — total: $total, renamed: $renamed, skipped (excluded): $skipped"
}

# --- Main ---
log "Repository: $REPO"
log "Dry run: $DRY_RUN"
echo ""

delete_konflux_branches
echo ""
rename_old_release_branches

echo ""
log "Done."
