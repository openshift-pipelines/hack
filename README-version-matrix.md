# Version Compatibility Matrix

This document describes how the version compatibility matrix is used to manage component updates in the OpenShift Pipelines ecosystem.

## Overview

The OpenShift Pipelines project consists of multiple components that are packaged together in releases. As the project evolves, different components may be added or removed from specific releases. The version compatibility matrix (`version-compatibility-matrix.json`) tracks which components are included in each release version and their corresponding component versions.

## Matrix Structure

The `version-compatibility-matrix.json` file contains a structured mapping of:

- Release versions (e.g., "1.16")
- Supported OCP versions
- Kubernetes versions
- Component versions (pipelines, triggers, tkn, etc.)

Each release entry includes a `components` object that lists the specific versions of each component included in that release. If a component is not present in a release, its value will be `null` in the matrix.

Example structure:
```json
{
  "version_compatibility_matrix": [
    {
      "version": "1.16",
      "ocp": ["4.15", "4.16", "4.17"],
      "k8s": ["1.28", "1.29", "1.30"],
      "minimum_k8s_version": "1.28",
      "components": {
        "operator": "0.73.x",
        "pipelines": "0.62.x",
        "triggers": "0.29.x",
        "tkn": "0.38.x",
        "pac": "0.28.x",
        "chains": "0.22.x",
        "hub": "1.18.x",
        "results": "0.12.x",
        "catalog": null,
        "manual_approval": "0.3.x",
        "opc": "1.16.x"
      }
    }
  ]
}
```

## Integration with Update Scripts

The `hack/update-all.sh` script uses the version compatibility matrix to determine which repository configurations should be updated when preparing a new release. This ensures that only relevant components for a specific version are updated.

### How It Works

1. When you run `make update VERSION=1.16`, it calls `hack/update-all.sh` with the specified version.
2. The script reads the version compatibility matrix to identify which components are included in version 1.16.
3. It then updates only the repositories corresponding to the included components.

### Excluded Repositories

The following repositories are excluded from automatic updates:
- `console-plugin`: The OpenShift Console plugin for Pipelines
- `manual-approval-gate`: The Manual Approval Gate component
- `tekton-caches`: The Tekton Cache component

These repositories must be updated manually if needed.

### Component to Repository Mapping

The script maps component names in the matrix to repository names as follows:

| Component in Matrix | Repository Name |
|---------------------|----------------|
| pipelines | tektoncd-pipeline |
| triggers | tektoncd-triggers |
| tkn | tektoncd-cli |
| pac | pac-downstream |
| chains | tektoncd-chains |
| hub | tektoncd-hub |
| results | tektoncd-results |
| manual_approval | manual-approval-gate |
| console_plugin | console-plugin |
| opc | opc-downstream |

### Benefits

This approach ensures that:

1. Only relevant repositories are updated for a given release version
2. Components not included in a release are not inadvertently modified
3. Repository configurations remain consistent with the components actually included in the release

## Requirements

The update scripts require the `jq` command-line JSON processor to parse the version compatibility matrix. If `jq` is not installed, the script will display a warning and continue without component filtering.

To install `jq`:
- On macOS: `brew install jq`
- On Fedora/RHEL: `dnf install jq`
- On Ubuntu/Debian: `apt-get install jq`

## Updating the Matrix

When adding new components or creating new releases, update the `version-compatibility-matrix.json` file to reflect the new component compositions. This ensures the update scripts will correctly handle future releases. 