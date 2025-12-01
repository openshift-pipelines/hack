#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"


source $SCRIPT_DIR/common-functions.sh

# Default values
DEFAULT_ACTION="update-upstream-versions"
DEFAULT_VERSION="next"
ACTION=""
VERSION=""


help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Required Flags:
  --action, -a        Action to perform. Supported values:
                        * new-release              Create a new release version
                        * new-patch                Create a new patch version
                        * update-upstream-versions Update upstream related versions

  --version, -v       Version to operate on (e.g., 1.23.0)

Optional Flags:
  --env, --environment, -e   Target environment (optional)
  --help, -h                 Show this help message and exit

Examples:
  $0 --action new-release --version 1.23.0
  $0 -a new-patch -v 1.23.0
  $0 -a update-upstream-versions -v 1.24.0

Description:
  This script automates release version operations. It will call different
  internal functions based on the selected action:
    - create-new-release
    - create-new-patch
    - update-upstream-versions
EOF
  exit 1
}

# Parse named args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --action | -a)
      ACTION="$2"
      shift 2
      ;;
    --version | -v)
      VERSION="$2"
      shift 2
      ;;
    --help|-h)
      help
      ;;
    *)
      echo "Unknown parameter: $1"
      help
      ;;
  esac
done

# Use Default Values for required params
if [[ -z "$ACTION"  ]]; then
  echo "Using default action $DEFAULT_ACTION!"
  ACTION=$DEFAULT_ACTION
fi
if [[ -z "$VERSION"  ]]; then
  echo "Using default version $DEFAULT_VERSION!"
  VERSION=$DEFAULT_VERSION
fi

# Call specific function based on ACTION
case "$ACTION" in
  "new-release")
    create-new-release $VERSION
    ;;
  "new-patch")
    create-new-patch $VERSION
    ;;
  "update-upstream-versions")
    update-upstream-versions $VERSION
    ;;
  *)
    echo "Invalid action: $ACTION"
    help
    ;;
esac
