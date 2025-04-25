#!/bin/bash

set -e

# Script to update repository configurations in config/konflux/repos directory
# 
# This script handles two cases:
# Case 1: Repos with both upstream and downstream (with upstream field)
# Case 2: Repos with only downstream (no upstream field)
#
# Usage: ./hack/update-repo-config.sh [--dry-run] <command> [options]
#
# Commands:
#   update-version <repo_name> <old_version> <new_version>
#     Updates the version in the specified repo config
#     Example: ./hack/update-repo-config.sh update-version tektoncd-cli 1.15 1.16
#
#   update-branch <repo_name> <branch_name> <upstream_branch>
#     Updates or adds a branch in the specified repo config
#     For repos with upstream: ./hack/update-repo-config.sh update-branch tektoncd-cli release-v1.16.x release-v0.60.x
#     For repos without upstream: ./hack/update-repo-config.sh update-branch console-plugin release-v0.3.0
#
#   replace-branch <repo_name> <old_branch_name> <new_branch_name> <upstream_branch>
#     Replaces an existing branch with a new branch name
#     For repos with upstream: ./hack/update-repo-config.sh replace-branch tektoncd-cli next release-v1.16.x release-v0.60.x
#     For repos without upstream: ./hack/update-repo-config.sh replace-branch console-plugin next release-v0.3.0
#
#   list
#     Lists all repositories and their configurations
#     Example: ./hack/update-repo-config.sh list
#
#   show <repo_name>
#     Shows the configuration for a specific repository
#     Example: ./hack/update-repo-config.sh show tektoncd-cli

# Parse arguments
DRY_RUN=false
if [ "$1" == "--dry-run" ]; then
    DRY_RUN=true
    shift
fi

COMMAND=$1
REPOS_DIR="config/konflux/repos"

# Function to display usage information
function show_usage {
    echo "Usage: $0 [--dry-run] <command> [options]"
    echo ""
    echo "Commands:"
    echo "  update-version <repo_name> <old_version> <new_version>"
    echo "    Updates the version in the specified repo config"
    echo "    Example: $0 update-version tektoncd-cli 1.15 1.16"
    echo ""
    echo "  update-branch <repo_name> <branch_name> <upstream_branch>"
    echo "    Updates or adds a branch in the specified repo config"
    echo "    For repos with upstream: $0 update-branch tektoncd-cli release-v1.16.x release-v0.60.x"
    echo "    For repos without upstream: $0 update-branch console-plugin release-v0.3.0"
    echo ""
    echo "  replace-branch <repo_name> <old_branch_name> <new_branch_name> <upstream_branch>"
    echo "    Replaces an existing branch with a new branch name"
    echo "    For repos with upstream: $0 replace-branch tektoncd-cli next release-v1.16.x release-v0.60.x"
    echo "    For repos without upstream: $0 replace-branch console-plugin next release-v0.3.0"
    echo ""
    echo "  list"
    echo "    Lists all repositories and their configurations"
    echo "    Example: $0 list"
    echo ""
    echo "  show <repo_name>"
    echo "    Shows the configuration for a specific repository"
    echo "    Example: $0 show tektoncd-cli"
    echo ""
    echo "Options:"
    echo "  --dry-run      Only show what would be changed, don't modify files"
}

# Function to check if a repository has an upstream
function has_upstream {
    local repo_file="$REPOS_DIR/$1.yaml"
    if [ ! -f "$repo_file" ]; then
        echo "Error: Repository file $repo_file does not exist" >&2
        return 1
    fi
    
    grep -q "^upstream:" "$repo_file"
    return $?
}

# Function to list all repositories
function list_repos {
    echo "Repositories in $REPOS_DIR:"
    echo "============================"
    
    for file in $(find "$REPOS_DIR" -name "*.yaml" | sort); do
        repo_name=$(basename "$file" .yaml)
        repo_type="downstream-only"
        
        if has_upstream "$repo_name"; then
            upstream=$(grep "^upstream:" "$file" | awk '{print $2}')
            repo_type="upstream: $upstream"
        fi
        
        echo "$repo_name ($repo_type)"
        
        # List branches and versions - simplified approach
        echo "  Branches:"
        grep -A3 "  - name:" "$file" | grep -v "^--$" | sed 's/^/    /'
        
        # List components - simplified approach
        echo "  Components:"
        grep "  - name:" "$file" | sed 's/^/    /'
        echo ""
    done
}

# Function to show a specific repository
function show_repo {
    local repo_name=$1
    local repo_file="$REPOS_DIR/$repo_name.yaml"
    
    if [ ! -f "$repo_file" ]; then
        echo "Error: Repository file $repo_file does not exist" >&2
        return 1
    fi
    
    echo "Repository: $repo_name"
    echo "================================"
    cat "$repo_file"
    echo ""
}

# Function to update the version in a repository
function update_version {
    local repo_name=$1
    local old_version=$2
    local new_version=$3
    local repo_file="$REPOS_DIR/$repo_name.yaml"
    
    if [ ! -f "$repo_file" ]; then
        echo "Error: Repository file $repo_file does not exist" >&2
        return 1
    fi
    
    echo "Updating version in $repo_name from '$old_version' to '$new_version'"
    
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Would update $repo_file"
        echo "Versions section from file:"
        sed -n '/versions:/,/^[a-z]/p' "$repo_file" | sed 's/^/  /'
        return 0
    fi
    
    # Make a copy for comparison if changes are made
    cp "$repo_file" "$repo_file.prev"
    has_changes=false
    
    # Create a temporary file for processing
    temp_file=$(mktemp)
    
    # Process the file line by line
    while IFS= read -r line; do
        # Check if the line contains a version entry
        if [[ "$line" =~ [[:space:]]+\-[[:space:]]\"$old_version\" ]] || [[ "$line" =~ [[:space:]]+\-[[:space:]]$old_version$ ]]; then
            # Replace the old version with the new version, keeping the same format (quoted or not)
            if [[ "$line" =~ \"$old_version\" ]]; then
                # Version is quoted
                echo "$line" | sed "s/\"$old_version\"/\"$new_version\"/" >> "$temp_file"
            else
                # Version is not quoted
                echo "$line" | sed "s/$old_version$/$new_version/" >> "$temp_file"
            fi
            has_changes=true
        else
            # Copy the line unchanged
            echo "$line" >> "$temp_file"
        fi
    done < "$repo_file"
    
    # Replace the original file with our modified version
    mv "$temp_file" "$repo_file"
    
    echo "Updated: $repo_file"
    
    # Only show diff if changes were made
    if [ "$has_changes" = true ]; then
        echo "Lines changed:"
        diff -u "$repo_file.prev" "$repo_file" | grep -E "^\+|^-" | grep -v "^@@" | sed 's/^/  /' || echo "  No changes needed"
    else
        echo "No version references found to update"
    fi
    
    # Remove the temporary comparison file
    rm -f "$repo_file.prev"
    
    return 0
}

# Function to update or add a branch in a repository
function update_branch {
    local repo_name=$1
    local branch_name=$2
    local upstream_branch=$3
    local repo_file="$REPOS_DIR/$repo_name.yaml"
    
    if [ ! -f "$repo_file" ]; then
        echo "Error: Repository file $repo_file does not exist" >&2
        return 1
    fi
    
    # Check if the repo has an upstream field
    local has_upstream_field=false
    if has_upstream "$repo_name"; then
        has_upstream_field=true
        
        # For repos with upstream, we need the upstream branch
        if [ -z "$upstream_branch" ] && [ "$has_upstream_field" = true ]; then
            echo "Error: Upstream branch is required for repos with upstream field" >&2
            return 1
        fi
    fi
    
    echo "Updating branch in $repo_name: branch=$branch_name"
    if [ "$has_upstream_field" = true ]; then
        echo "                           upstream=$upstream_branch"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Would update $repo_file"
        return 0
    fi
    
    # Make a temporary copy to compare changes later - only do this once we're sure we'll modify the file
    cp "$repo_file" "$repo_file.prev"
    
    # Check if the branch already exists
    if grep -q "^  - name: $branch_name" "$repo_file"; then
        echo "Branch $branch_name already exists, updating it"
        
        # Use sed to update the branch
        if [ "$has_upstream_field" = true ]; then
            # Find the line with the branch name and then update the upstream line
            line_num=$(grep -n "^  - name: $branch_name" "$repo_file" | cut -d: -f1)
            next_line=$((line_num + 1))
            
            # Check if next line is upstream
            if grep -q "^    upstream:" <(sed -n "${next_line}p" "$repo_file"); then
                # Replace existing upstream line
                sed -i "${next_line}s/.*upstream:.*/    upstream: $upstream_branch/" "$repo_file"
            else
                # Insert upstream line after branch name
                sed -i "${line_num}a\\    upstream: $upstream_branch" "$repo_file"
            fi
        fi
    else
        echo "Branch $branch_name does not exist, adding it"
        
        # Check if the branches section exists
        if ! grep -q "^branches:" "$repo_file"; then
            echo "No branches section found, adding it"
            # Add branches section with the new branch
            cat <<EOF >> "$repo_file"
branches:
  - name: $branch_name
EOF
            if [ "$has_upstream_field" = true ]; then
                echo "    upstream: $upstream_branch" >> "$repo_file"
            fi
            cat <<EOF >> "$repo_file"
    versions:
      - "next"
EOF
        else
            # Add new branch to existing branches section
            # Find the last branch entry
            last_branch_line=$(grep -n "^  - name:" "$repo_file" | tail -1 | cut -d: -f1)
            
            # Find the next section after branches
            next_section_line=$(grep -n "^[a-z]" "$repo_file" | awk -v start=$last_branch_line '$1 > start {print $1; exit}' | cut -d: -f1)
            
            if [ -z "$next_section_line" ]; then
                # If there's no next section, add to the end of the file
                cat <<EOF >> "$repo_file"
  - name: $branch_name
EOF
                if [ "$has_upstream_field" = true ]; then
                    echo "    upstream: $upstream_branch" >> "$repo_file"
                fi
                cat <<EOF >> "$repo_file"
    versions:
      - "next"
EOF
            else
                # Insert before the next section
                temp_file=$(mktemp)
                head -n $((next_section_line - 1)) "$repo_file" > "$temp_file"
                cat <<EOF >> "$temp_file"
  - name: $branch_name
EOF
                if [ "$has_upstream_field" = true ]; then
                    echo "    upstream: $upstream_branch" >> "$temp_file"
                fi
                cat <<EOF >> "$temp_file"
    versions:
      - "next"
EOF
                tail -n +$next_section_line "$repo_file" >> "$temp_file"
                mv "$temp_file" "$repo_file"
            fi
        fi
    fi
    
    echo "Updated: $repo_file"
    echo "Changes made:"
    diff -u "$repo_file.prev" "$repo_file" | grep -E "^\+|^-" | grep -v "^@@" | sed 's/^/  /' || echo "  No changes needed"
    
    # Remove the temporary comparison file
    rm -f "$repo_file.prev"
    
    return 0
}

# Function to replace a branch in a repository
function replace_branch {
    local repo_name=$1
    local old_branch_name=$2
    local new_branch_name=$3
    local upstream_branch=$4
    local new_version=$5
    local repo_file="$REPOS_DIR/$repo_name.yaml"
    
    if [ ! -f "$repo_file" ]; then
        echo "Error: Repository file $repo_file does not exist" >&2
        return 1
    fi
    
    # Check if the repo has an upstream field
    local has_upstream_field=false
    if has_upstream "$repo_name"; then
        has_upstream_field=true
        
        # For repos with upstream, we need the upstream branch - but allow keeping the current one
        if [ -z "$upstream_branch" ] && [ "$has_upstream_field" = true ]; then
            # Extract existing upstream branch to preserve it
            existing_branch_line=$(grep -n "^  - name: $old_branch_name" "$repo_file" | cut -d: -f1)
            if [ -n "$existing_branch_line" ]; then
                next_line=$((existing_branch_line + 1))
                if grep -q "^    upstream:" <(sed -n "${next_line}p" "$repo_file"); then
                    upstream_branch=$(sed -n "${next_line}p" "$repo_file" | sed 's/^    upstream: //')
                    echo "Using existing upstream branch: $upstream_branch"
                fi
            fi
            
            # If still empty, report error
            if [ -z "$upstream_branch" ]; then
                echo "Error: Upstream branch is required for repos with upstream field" >&2
                return 1
            fi
        fi
    fi
    
    echo "Replacing branch in $repo_name: $old_branch_name -> $new_branch_name"
    if [ "$has_upstream_field" = true ] && [ -n "$upstream_branch" ]; then
        echo "                           (keeping upstream branch: $upstream_branch)"
    fi
    if [ -n "$new_version" ]; then
        echo "                           (updating version references from 'next' to '$new_version')"
    fi
    
    if [ "$DRY_RUN" = true ]; then
        echo "DRY RUN: Would update $repo_file"
        return 0
    fi
    
    # First, let's check if the file contains the branch we want to replace
    if ! grep -q "^  - name: $old_branch_name" "$repo_file"; then
        echo "Branch $old_branch_name does not exist in $repo_file - skipping"
        # Skip this repo instead of returning error
        return 0
    fi
    
    # Check if the file contains any special version format (e.g., next%)
    if grep -q "next%" "$repo_file"; then
        echo "Detected special version format with '%' in $repo_file"
        # Mark that we should preserve the % suffix
        preserve_percent=true
    else
        preserve_percent=false
    fi
    
    # Create a temporary file for our updated content
    temp_file=$(mktemp)
    
    # Debug output - print the original file structure
    echo "Original file structure for debugging:"
    grep -A10 "^  - name: $old_branch_name" "$repo_file" | sed 's/^/  DEBUG: /'
    
    # Make a backup for comparison
    cp "$repo_file" "$repo_file.prev"
    
    # Use awk for more precise pattern matching and replacement
    awk -v old_branch="$old_branch_name" -v new_branch="$new_branch_name" \
        -v new_version="$new_version" -v upstream="$upstream_branch" \
        -v preserve_percent="$preserve_percent" '
    BEGIN {
        in_branch = 0;
        in_versions = 0;
        branch_indent = "";
    }
    
    # Detect when entering or leaving a branch entry
    /^  - name:/ {
        # If we were in a branch, we are now leaving it
        if (in_branch) {
            in_branch = 0;
            in_versions = 0;
        }
        
        # If this is the branch we want to replace
        if ($0 ~ "^  - name: *" old_branch) {
            in_branch = 1;
            branch_indent = "  ";
            print branch_indent "- name: " new_branch;
            next;
        }
    }
    
    # Handle upstream line if we are in the target branch
    in_branch && /^    upstream:/ {
        if (upstream != "") {
            print "    upstream: " upstream;
        } else {
            print $0;  # Preserve existing value
        }
        next;
    }
    
    # Detect versions section
    in_branch && /^    versions:/ {
        in_versions = 1;
        print $0;
        next;
    }
    
    # Handle version entries in the versions section
    in_versions && /^      -/ {
        if (($0 ~ /next/ || $0 ~ /next%/) && new_version != "") {
            # Check if we need to preserve the % suffix
            suffix = "";
            if (preserve_percent == "true" && $0 ~ /%/) {
                suffix = "%";
            }
            
            # Replace next with new version, preserving quotes and special characters if present
            if ($0 ~ /"next%"/ || $0 ~ /"next"/) {
                gsub(/"next%?"/, "\"" new_version suffix "\"");
            } else {
                gsub(/next%?/, new_version suffix);
            }
        }
        print $0;
        next;
    }
    
    # Print all other lines unchanged
    { print $0 }
    ' "$repo_file" > "$temp_file"
    
    # Replace the original with our modified version
    mv "$temp_file" "$repo_file"
    
    echo "Updated: $repo_file"
    echo "Changes made:"
    diff -u "$repo_file.prev" "$repo_file" | grep -E "^\+|^-" | grep -v "^@@" | sed 's/^/  /' || echo "  No changes needed"
    
    # Remove the temporary files
    rm -f "$repo_file.prev"
    
    return 0
}

# Main logic
case "$COMMAND" in
    list)
        list_repos
        ;;
        
    show)
        if [ -z "$2" ]; then
            echo "Error: Repository name required for 'show' command" >&2
            show_usage
            exit 1
        fi
        show_repo "$2"
        ;;
        
    update-version)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
            echo "Error: Repository name, old version, and new version required for 'update-version' command" >&2
            show_usage
            exit 1
        fi
        update_version "$2" "$3" "$4"
        ;;
        
    update-branch)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Error: Repository name and branch name required for 'update-branch' command" >&2
            show_usage
            exit 1
        fi
        update_branch "$2" "$3" "$4"
        ;;
        
    replace-branch)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
            echo "Error: Repository name, old branch name, and new branch name required for 'replace-branch' command" >&2
            show_usage
            exit 1
        fi
        replace_branch "$2" "$3" "$4" "$5" "$6"
        ;;
        
    *)
        echo "Error: Unknown or missing command: $COMMAND" >&2
        show_usage
        exit 1
        ;;
esac

echo ""
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN completed. To actually update the files, run without --dry-run"
else
    echo "Repository update completed."
fi 