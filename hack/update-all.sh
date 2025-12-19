#!/bin/bash

set -e

# One command to update everything with simplified parameters
# 
# This script is a simplified wrapper around update-configs.sh
# that auto-generates some of the parameters based on the version
#
# It uses the version-compatibility-matrix.json to determine which
# components should be updated for the specified version.
#
# Usage: ./hack/update-all.sh [--dry-run] <new_version> <image_suffix>
#
# Example: ./hack/update-all.sh 1.16 -rhel8
#          ./hack/update-all.sh --dry-run 1.16 -rhel8
#
# Parameters:
#   <new_version>    - The new version number (e.g., "1.16")
#   <image_suffix>   - The image suffix (e.g., "-rhel8", "-rhel9")
#
# Options:
#   --dry-run        - Show what would be changed without actually making changes

# Parse arguments
DRY_RUN=""
if [ "$1" == "--dry-run" ]; then
    DRY_RUN="--dry-run"
    shift
fi

if [ "$#" -lt 2 ]; then
    echo "Error: Not enough arguments"
    echo "Usage: $0 [--dry-run] <new_version> <image_suffix>"
    echo "Example: $0 1.16 -rhel8"
    exit 1
fi

# Set parameters
NEW_VERSION=$1
IMAGE_SUFFIX=$2
OLD_VERSION="next"

# Check if the version includes a patch version (e.g., 0.5.0)
if [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    # For versions like 0.5.0, use release-v0.5.0
    BRANCH_PATTERN="release-v$NEW_VERSION"
else
    # For versions like 0.5, use release-v0.5.x
    BRANCH_PATTERN="release-v$NEW_VERSION.x"
fi

echo "==================================================================="
echo "Starting unified update process with the following parameters:"
echo "  Old Version:    $OLD_VERSION"
echo "  New Version:    $NEW_VERSION"
echo "  Image Suffix:   $IMAGE_SUFFIX" 
echo "  Branch Pattern: $BRANCH_PATTERN"
if [ -n "$DRY_RUN" ]; then
    echo "  DRY RUN MODE: No changes will be made"
fi
echo "==================================================================="
echo ""
echo "Note: The following repositories will be excluded from updates:"
echo "  - console-plugin"
echo "  - manual-approval-gate"
echo "  - tekton-caches"
echo ""

# Check if version-compatibility-matrix.json exists
if [ -f "version-compatibility-matrix.json" ]; then
    echo "Using version compatibility matrix to filter components for version $NEW_VERSION"
else
    echo "Warning: version-compatibility-matrix.json not found."
    echo "All repositories will be updated regardless of component compatibility."
fi

echo ""

# Call the main update script with our parameters
./hack/update-configs.sh $DRY_RUN $OLD_VERSION $NEW_VERSION $IMAGE_SUFFIX $BRANCH_PATTERN

echo ""
echo "==================================================================="
if [ -n "$DRY_RUN" ]; then
    echo "DRY RUN COMPLETE - No files were modified"
    echo "To apply these changes, run without the --dry-run flag"
else
    echo "ALL UPDATES COMPLETE"
    echo ""
    echo "Next steps:"
    echo "1. Review the changes made to the configuration files"
    echo "2. Generate the Konflux files: go run ./cmd/konflux/ -config config/konflux/<appropriate-files>"
    echo "3. Commit and push the changes"
fi
echo "===================================================================" 
