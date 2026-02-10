# Update Dockerfile Labels

This tool updates CPE labels in Dockerfiles across all component repositories.

## Features

- ✅ **Validation**: Checks that each Dockerfile has a LABEL block with a required `name` key
- ✅ **Smart Updates**: Appends CPE label to existing multi-line LABEL blocks
- ✅ **Re-run Safe**: Re-running the tool updates existing PRs via force push (no duplicates)
- ✅ **Error Handling**: Clear warnings and errors for missing required fields

## Usage

### Via GitHub Actions (Recommended)

1. Go to the [Actions tab](../../actions/workflows/update-dockerfile-labels.yaml) in this repository
2. Click "Run workflow"
3. Enter the version for the CPE label (e.g., `1.21`)
4. Click "Run workflow"

The workflow will:
- Clone all component repositories
- Update all Dockerfiles in `.konflux/dockerfiles/` directories
- Create pull requests with the changes

### Via Command Line

```bash
# Update with default version (1.21)
go run ./cmd/update-dockerfile-labels/ \
  config/konflux/openshift-pipelines-core.yaml \
  config/konflux/openshift-pipelines-cli.yaml \
  config/konflux/openshift-pipelines-operator.yaml

# Update with specific version
go run ./cmd/update-dockerfile-labels/ \
  --version 1.22 \
  config/konflux/openshift-pipelines-core.yaml

# Dry run (no commits, no PRs)
go run ./cmd/update-dockerfile-labels/ \
  --dry-run \
  --version 1.21 \
  config/konflux/openshift-pipelines-core.yaml
```

## What it does

1. Reads configuration files to discover all repositories and branches
2. For each repository:
   - Clones/updates the repository
   - Finds all `*.Dockerfile` files in `.konflux/dockerfiles/`
   - Adds or updates the CPE LABEL:
     ```dockerfile
     LABEL cpe="cpe:/a:redhat:openshift_pipelines:1.21::el9"
     ```
   - Creates a commit with the changes
   - Pushes to a branch named `actions/update/dockerfile-labels-<config-name>-<branch-name>`
   - Creates a pull request if one doesn't exist

## Repositories covered

All repositories defined in the config files:
- openshift-pipelines-operator
- tektoncd-pipeline
- tektoncd-triggers
- tektoncd-results
- tektoncd-chains
- tektoncd-hub
- tektoncd-cli
- pac-downstream
- manual-approval-gate
- console-plugin
- git-init
- tekton-caches
- tektoncd-pruner
- opc

## Label format

The CPE label follows the format:
```
cpe:/a:redhat:openshift_pipelines:<version>::el9
```

Example for version 1.21:
```dockerfile
LABEL cpe="cpe:/a:redhat:openshift_pipelines:1.21::el9"
```
