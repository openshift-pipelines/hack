#!/bin/bash

# DEPRECATED: This script is deprecated. Please use the GitHub Actions workflow instead.
# See: .github/workflows/update-dockerfile-labels.yaml
# Or use the Go command: go run ./cmd/update-dockerfile-labels/
#
# Script to update LABEL in Dockerfiles across all component repositories
# Usage: ./update-dockerfile-labels.sh <version> <working-directory>
# Example: ./update-dockerfile-labels.sh 1.21 /tmp/dockerfile-updates

set -e

VERSION=${1:-"1.21"}
WORK_DIR=${2:-"/tmp/dockerfile-updates"}
CPE_LABEL="cpe=\"cpe:/a:redhat:openshift_pipelines:${VERSION}::el9\""

GITHUB_ORG="openshift-pipelines"

# Color output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting Dockerfile label update process...${NC}"
echo "Version: ${VERSION}"
echo "Working directory: ${WORK_DIR}"
echo "CPE Label: ${CPE_LABEL}"
echo ""

# Create working directory
mkdir -p "${WORK_DIR}"

# Define repositories and their Dockerfiles based on config
declare -A REPOS_DOCKERFILES=(
    ["operator"]=".konflux/dockerfiles/operator.Dockerfile .konflux/dockerfiles/webhook.Dockerfile .konflux/dockerfiles/proxy.Dockerfile"
    ["tektoncd-pipeline"]=".konflux/dockerfiles/controller.Dockerfile .konflux/dockerfiles/webhook.Dockerfile .konflux/dockerfiles/events.Dockerfile .konflux/dockerfiles/resolvers.Dockerfile .konflux/dockerfiles/entrypoint.Dockerfile .konflux/dockerfiles/nop.Dockerfile .konflux/dockerfiles/sidecarlogresults.Dockerfile .konflux/dockerfiles/workingdirinit.Dockerfile"
    ["tektoncd-triggers"]=".konflux/dockerfiles/controller.Dockerfile .konflux/dockerfiles/webhook.Dockerfile .konflux/dockerfiles/core-interceptors.Dockerfile .konflux/dockerfiles/eventlistenersink.Dockerfile"
    ["tektoncd-results"]=".konflux/dockerfiles/api.Dockerfile .konflux/dockerfiles/watcher.Dockerfile .konflux/dockerfiles/retention-policy-agent.Dockerfile"
    ["tektoncd-chains"]=".konflux/dockerfiles/controller.Dockerfile"
    ["tektoncd-hub"]=".konflux/dockerfiles/api.Dockerfile .konflux/dockerfiles/ui.Dockerfile .konflux/dockerfiles/db-migration.Dockerfile"
    ["tektoncd-cli"]=".konflux/dockerfiles/tkn.Dockerfile"
    ["pac-downstream"]=".konflux/dockerfiles/controller.Dockerfile .konflux/dockerfiles/webhook.Dockerfile .konflux/dockerfiles/watcher.Dockerfile .konflux/dockerfiles/cli.Dockerfile"
    ["manual-approval-gate"]=".konflux/dockerfiles/controller.Dockerfile .konflux/dockerfiles/webhook.Dockerfile"
    ["console-plugin"]=".konflux/dockerfiles/console-plugin.Dockerfile"
    ["git-init"]=".konflux/dockerfiles/git-init.Dockerfile"
    ["tekton-caches"]=".konflux/dockerfiles/cache.Dockerfile"
    ["tektoncd-pruner"]=".konflux/dockerfiles/controller.Dockerfile"
    ["opc"]=".konflux/dockerfiles/opc.Dockerfile"
)

update_dockerfile_label() {
    local dockerfile="$1"
    
    if [[ ! -f "$dockerfile" ]]; then
        echo -e "${RED}  ✗ File not found: $dockerfile${NC}"
        return 1
    fi
    
    # Check if the label already exists
    if grep -q "LABEL.*cpe=" "$dockerfile"; then
        echo -e "${YELLOW}  ⚠ CPE label already exists, replacing...${NC}"
        # Replace existing CPE label
        sed -i.bak -E "s|LABEL.*cpe=.*|LABEL ${CPE_LABEL}|g" "$dockerfile"
    else
        # Append the label at the end of the file
        echo "" >> "$dockerfile"
        echo "LABEL ${CPE_LABEL}" >> "$dockerfile"
    fi
    
    echo -e "${GREEN}  ✓ Updated: $dockerfile${NC}"
    return 0
}

# Process each repository
for repo in "${!REPOS_DOCKERFILES[@]}"; do
    echo -e "${YELLOW}================================================${NC}"
    echo -e "${YELLOW}Processing repository: ${repo}${NC}"
    echo -e "${YELLOW}================================================${NC}"
    
    REPO_URL="https://github.com/${GITHUB_ORG}/${repo}.git"
    CLONE_DIR="${WORK_DIR}/${repo}"
    
    # Clone or pull the repository
    if [[ -d "${CLONE_DIR}" ]]; then
        echo "Repository already exists, pulling latest changes..."
        cd "${CLONE_DIR}"
        git pull origin main 2>/dev/null || git pull origin master 2>/dev/null || echo "Could not pull"
    else
        echo "Cloning repository..."
        git clone "${REPO_URL}" "${CLONE_DIR}"
        cd "${CLONE_DIR}"
    fi
    
    # Update each Dockerfile
    DOCKERFILES=${REPOS_DOCKERFILES[$repo]}
    for dockerfile in ${DOCKERFILES}; do
        echo "Updating ${dockerfile}..."
        update_dockerfile_label "${dockerfile}"
    done
    
    # Show git status
    echo ""
    echo "Git status:"
    git status --short
    echo ""
done

echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}Dockerfile label update completed!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo "Next steps:"
echo "1. Review the changes in ${WORK_DIR}"
echo "2. For each repository, commit and push the changes:"
echo "   cd ${WORK_DIR}/<repo-name>"
echo "   git add .konflux/dockerfiles/*.Dockerfile"
echo "   git commit -m 'Add CPE label to Dockerfiles'"
echo "   git push origin <branch-name>"
echo ""
