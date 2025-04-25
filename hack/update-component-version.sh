#!/bin/bash

set -e

# Script to update version and image-suffix in config/konflux YAML files
# 
# This script updates the version information in all YAML files in the config/konflux
# directory (not in config/konflux/repos). It can convert:
#
# versions:
#   next:
#     version: next
#     image-suffix: -rhel9
#     auto-release: true
#
# to:
#
# versions:
#   1.16:
#     version: 1.16
#     image-suffix: -rhel8
#     auto-release: true
#
# Usage: ./hack/update-component-version.sh [--dry-run] <old_version> <new_version> <new_image_suffix>
# Example: ./hack/update-component-version.sh next 1.16 -rhel8

# Parse arguments
DRY_RUN=false
if [ "$1" == "--dry-run" ]; then
    DRY_RUN=true
    shift
fi

if [ "$#" -lt 3 ]; then
    echo "Usage: $0 [--dry-run] <old_version> <new_version> <new_image_suffix>"
    echo "Example: $0 next 1.16 -rhel8"
    echo ""
    echo "  --dry-run      Only show what would be changed, don't modify files"
    exit 1
fi

OLD_VERSION=$1
NEW_VERSION=$2
NEW_IMAGE_SUFFIX=$3
CONFIG_DIR="config/konflux"

echo "========================================================================"
echo "Updating YAML files in $CONFIG_DIR (excluding repos directory)"
echo "Old version: $OLD_VERSION"
echo "New version: $NEW_VERSION"
echo "New image suffix: $NEW_IMAGE_SUFFIX"
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: No files will be modified"
fi
echo "========================================================================"
echo ""

# Process each YAML file in the config/konflux directory
for file in $(find $CONFIG_DIR -maxdepth 1 -name "*.yaml"); do
    echo "Processing file: $file"
    
    # Check if the file contains the old version under versions
    if grep -q "versions:" "$file" && grep -q "  $OLD_VERSION:" "$file"; then
        echo "  Found version '$OLD_VERSION' in file, updating..."
        
        if [ "$DRY_RUN" = true ]; then
            echo "  DRY RUN: Would update $file"
            continue
        fi
        
        # Use awk to process the YAML file
        awk -v old_ver="$OLD_VERSION" -v new_ver="$NEW_VERSION" -v new_suffix="$NEW_IMAGE_SUFFIX" '
        # Track if we are in the versions section
        /^versions:/ { in_versions = 1; print; next }
        /^[a-z]/ && !/^[ \t]/ { in_versions = 0 }  # Reset when we hit a new top-level key
        
        # Match the version key line (with proper indentation)
        in_versions && $0 ~ "  "old_ver":" {
            gsub("  "old_ver":", "  "new_ver":");
            print;
            next;
        }
        
        # Match the version value line
        in_versions && $0 ~ /[ ]+version:/ && $0 ~ old_ver {
            gsub(old_ver, new_ver);
            print;
            next;
        }
        
        # Match the image-suffix line
        in_versions && $0 ~ /[ ]+image-suffix:/ {
            sub(/image-suffix:[ ]*.*/, "image-suffix: "new_suffix);
            print;
            next;
        }
        
        # Print all other lines unchanged
        { print }
        ' "$file" > "${file}.tmp"
        
        # Replace the original file
        mv "${file}.tmp" "$file"
        
        echo "  Updated: $file"
    else
        echo "  Skipping file (version '$OLD_VERSION' not found or no versions section)"
    fi
done

echo ""
if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN completed. To actually update the files, run without --dry-run"
else
    echo "Version update completed."
fi
