#!/bin/bash

set -e

# Script to update both the main config files and repository configurations in one go
# 
# This script combines functionality from:
# - update-component-version.sh: Updates the version information in config/konflux/*.yaml files
# - update-repo-config.sh: Updates repository configurations in config/konflux/repos/*.yaml files
#
# Usage: ./hack/update-configs.sh [--dry-run] <old_version> <new_version> <image_suffix> [<branch_pattern>]
#
# Example: ./hack/update-configs.sh next 1.16 -rhel8 "release-v1.16.x"
#
# Parameters:
#   <old_version>    - The version to replace (e.g., "next")
#   <new_version>    - The new version (e.g., "1.16")
#   <image_suffix>   - The new image suffix (e.g., "-rhel8")
#   [<branch_pattern>] - Optional branch pattern (e.g., "release-v1.16.x")
#                       If provided, will update branches in repo configs
#
# Options:
#   --dry-run        - Show what would be changed without actually making changes

# Parse arguments
DRY_RUN=""
if [ "$1" == "--dry-run" ]; then
    DRY_RUN="--dry-run"
    shift
fi

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 [--dry-run] <old_version> <new_version> <image_suffix> [<branch_pattern>]"
    echo "Example: $0 next 1.16 -rhel8 release-v1.16.x"
    exit 1
fi

OLD_VERSION=$1
NEW_VERSION=$2
IMAGE_SUFFIX=$3
BRANCH_PATTERN=$4
OLD_BRANCH_NAME="next"
COMPATIBILITY_MATRIX="version-compatibility-matrix.json"

# Function to check if a component is present in the given version
is_component_present() {
    local version="$1"
    local component="$2"
    
    # Return 0 (true) if component is present and not null, 1 (false) otherwise
    if [ ! -f "$COMPATIBILITY_MATRIX" ]; then
        # If matrix file is not found, assume component is present (for backward compatibility)
        return 0
    fi
    
    # Use jq to query the compatibility matrix
    # Example: jq -r '.version_compatibility_matrix[] | select(.version == "1.16") | .components.pipelines'
    local component_version=$(jq -r ".version_compatibility_matrix[] | select(.version == \"$version\") | .components.$component" "$COMPATIBILITY_MATRIX" 2>/dev/null)
    
    # Remove (TP) designation if present for comparison purposes
    component_version=${component_version//" (TP)"/""}
    
    if [ -z "$component_version" ] || [ "$component_version" = "null" ]; then
        return 1  # Component not present
    else
        return 0  # Component present
    fi
}

# Function to get component type from repo name
get_component_type() {
    local repo_name="$1"
    
    # Map repository names to component types in the matrix
    case "$repo_name" in
        "tektoncd-pipeline") echo "pipelines" ;;
        "tektoncd-triggers") echo "triggers" ;;
        "tektoncd-cli") echo "tkn" ;;
        "pac-downstream") echo "pac" ;;
        "tektoncd-chains") echo "chains" ;;
        "tektoncd-hub") echo "hub" ;;
        "tektoncd-results") echo "results" ;;
        "manual-approval-gate") echo "manual_approval" ;;
        "console-plugin") echo "console_plugin" ;;
        "opc-downstream") echo "opc" ;;
        *) echo "" ;;  # Default: unknown mapping
    esac
}

# Function to update the main configuration files
update_main_configs() {
    echo "======================================================================"
    echo "STEP 1: Updating main configuration files"
    echo "======================================================================"
    ./hack/update-component-version.sh $DRY_RUN $OLD_VERSION $NEW_VERSION $IMAGE_SUFFIX
}

# Function to update repositories
update_repo_configs() {
    echo "======================================================================"
    echo "STEP 2: Updating repository configuration files"
    echo "======================================================================"
    
    echo ""
    echo "Updating versions in repositories relevant for version $NEW_VERSION..."
    echo "Note: Skipping console-plugin, manual-approval-gate, and tekton-caches repositories as requested."
    echo ""
    
    # Get all repo files
    repos_dir="config/konflux/repos"
    for repo_file in $(find "$repos_dir" -name "*.yaml"); do
        repo_name=$(basename "$repo_file" .yaml)
        component_type=$(get_component_type "$repo_name")
        
        # Skip any repo with "index" in name
        if [[ "$repo_name" == *index* ]]; then
            echo "Skipping $repo_name: index repository"
            continue
        fi

        # Skip excluded repositories
        if [[ "$repo_name" == "console-plugin" || "$repo_name" == "manual-approval-gate" || "$repo_name" == "tekton-caches" ]]; then
            echo "Skipping $repo_name: excluded from updates by configuration"
            continue
        fi
        
        # Check if component is present in the target version
        if [ -n "$component_type" ]; then
            if ! is_component_present "$NEW_VERSION" "$component_type"; then
                echo "Skipping $repo_name: component '$component_type' not present in version $NEW_VERSION"
                continue
            fi
        fi
        
        echo "Processing repository: $repo_name"
        
        # Update version in this repo
        ./hack/update-repo-config.sh $DRY_RUN update-version "$repo_name" "$OLD_VERSION" "$NEW_VERSION"
    done
    
    # Update branches if a branch pattern was provided
    if [ -n "$BRANCH_PATTERN" ]; then
        echo ""
        echo "Replacing '$OLD_BRANCH_NAME' branch with '$BRANCH_PATTERN' in repositories for version $NEW_VERSION"
        echo "(Repositories without the '$OLD_BRANCH_NAME' branch will be skipped)"
        echo "(Excluded repositories: console-plugin, manual-approval-gate, tekton-caches)"
        echo "(Existing upstream branch configurations will be preserved)"
        echo "(Version references to 'next' will be updated to '$NEW_VERSION')"
        echo ""
        
        # For repos with upstream, determine upstream branch pattern
        # This is usually something like "release-v0.X.0" based on the downstream branch "release-v1.X.x"
        # The script tries to guess based on the repo name, but users might need to update manually
        
        for repo_file in $(find "$repos_dir" -name "*.yaml"); do
            repo_name=$(basename "$repo_file" .yaml)
            component_type=$(get_component_type "$repo_name")
            
            # Skip any repo with "index" in name
            if [[ "$repo_name" == *index* ]]; then
                continue
            fi

            # Skip excluded repositories
            if [[ "$repo_name" == "console-plugin" || "$repo_name" == "manual-approval-gate" || "$repo_name" == "tekton-caches" ]]; then
                echo "Skipping $repo_name: excluded from updates by configuration"
                continue
            fi
            
            # Check if component is present in the target version
            if [ -n "$component_type" ]; then
                if ! is_component_present "$NEW_VERSION" "$component_type"; then
                    echo "Skipping $repo_name: component '$component_type' not present in version $NEW_VERSION"
                    continue
                fi
            fi
            
            # Check if this has a 'next' branch to replace
            if grep -q "^  - name: $OLD_BRANCH_NAME" "$repo_file"; then
                has_next_branch=true
                has_next_version=false
            else
                has_next_branch=false
                # Check if it has any 'next' version references that need updating
                if grep -q " - next" "$repo_file" || grep -q " - \"next\"" "$repo_file" || grep -q " - next%" "$repo_file"; then
                    has_next_version=true
                else
                    has_next_version=false
                fi
            fi
            
            # If no next branch or version, skip this repo
            if [ "$has_next_branch" = false ] && [ "$has_next_version" = false ]; then
                echo "Skipping $repo_name: no 'next' branch or version references found"
                continue
            fi
            
            # Check if this repo has an upstream
            if grep -q "^upstream:" "$repo_file"; then
                # This is a repo with upstream, try to determine the upstream branch
                
                # Extract the repo version from patterns like "release-v1.16.x" -> "16"
                repo_version=$(echo "$BRANCH_PATTERN" | grep -oE 'v[0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+')
                
                # Default upstream branch - users might need to update this manually
                upstream_branch=""
                
                # Special cases based on repo name
                case "$repo_name" in
                    "tektoncd-cli")
                        # Usually uses pattern like "release-v0.X.0"
                        upstream_branch="release-v0.$(echo $repo_version | cut -d. -f1).0"
                        ;;
                    "tektoncd-pipeline")
                        # Usually uses pattern like "release-v0.X.0"
                        upstream_branch="release-v0.$(echo $repo_version | cut -d. -f1).0"
                        ;;
                    *)
                        # Default for other repos
                        if grep -q "release-v0" "$repo_file"; then
                            # If repo already has a "release-v0" branch, use similar pattern
                            current_upstream=$(grep "upstream: release-v0" "$repo_file" | head -1 | awk '{print $2}')
                            if [ -n "$current_upstream" ]; then
                                # Extract pattern from current upstream
                                pattern=$(echo "$current_upstream" | grep -oE 'release-v[0-9]+\.[0-9]+\.[0-9x]+')
                                if [ -n "$pattern" ]; then
                                    # Replace the version number
                                    upstream_branch="release-v0.$(echo $repo_version | cut -d. -f1).0"
                                fi
                            fi
                        fi
                        ;;
                esac
                
                if [ "$has_next_branch" = true ]; then
                    # This repo has a 'next' branch that needs to be replaced
                    if [ -n "$upstream_branch" ]; then
                        echo "Updating $repo_name: replacing branch $OLD_BRANCH_NAME with $BRANCH_PATTERN (upstream: $upstream_branch)"
                        # Don't specify upstream branch - let the script preserve the existing one
                        ./hack/update-repo-config.sh $DRY_RUN replace-branch "$repo_name" "$OLD_BRANCH_NAME" "$BRANCH_PATTERN" "" "$NEW_VERSION"
                    else
                        echo "Updating $repo_name: replacing branch $OLD_BRANCH_NAME with $BRANCH_PATTERN (preserving upstream branch)"
                        echo "Note: If you need to update the upstream branch manually:"
                        echo "  ./hack/update-repo-config.sh replace-branch $repo_name $OLD_BRANCH_NAME $BRANCH_PATTERN <upstream-branch>"
                        # Don't specify upstream branch - let the script preserve the existing one
                        ./hack/update-repo-config.sh $DRY_RUN replace-branch "$repo_name" "$OLD_BRANCH_NAME" "$BRANCH_PATTERN" "" "$NEW_VERSION"
                    fi
                elif [ "$has_next_version" = true ]; then
                    # This repo has 'next' version references that need to be updated
                    echo "Updating $repo_name: updating version references from 'next' to '$NEW_VERSION'"
                    ./hack/update-repo-config.sh $DRY_RUN update-version "$repo_name" "$OLD_VERSION" "$NEW_VERSION"
                fi
            else
                # This is a downstream-only repo, no upstream branch needed
                if [ "$has_next_branch" = true ]; then
                    echo "Updating $repo_name: replacing branch $OLD_BRANCH_NAME with $BRANCH_PATTERN (downstream-only)"
                    ./hack/update-repo-config.sh $DRY_RUN replace-branch "$repo_name" "$OLD_BRANCH_NAME" "$BRANCH_PATTERN" "" "$NEW_VERSION"
                elif [ "$has_next_version" = true ]; then
                    echo "Updating $repo_name: updating version references from 'next' to '$NEW_VERSION' (downstream-only)"
                    ./hack/update-repo-config.sh $DRY_RUN update-version "$repo_name" "$OLD_VERSION" "$NEW_VERSION"
                fi
            fi
        done
    fi
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Warning: 'jq' command not found. Component filtering may not work correctly."
    echo "To enable component filtering based on the compatibility matrix, please install jq."
    echo "Continuing without component filtering..."
fi

# Main execution
update_main_configs
update_repo_configs

echo ""
echo "======================================================================"
if [ -n "$DRY_RUN" ]; then
    echo "DRY RUN COMPLETE - No files were modified"
    echo "To apply these changes, run without the --dry-run flag"
else
    echo "ALL UPDATES COMPLETE"
fi
echo "======================================================================" 