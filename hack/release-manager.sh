#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"


source $SCRIPT_DIR/common-functions.sh

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
                        * new-rc                   Create a new RC version (increments RC number)
                        * finalize-rc              Finalize RC by dropping -RC suffix
                        * update-upstream-versions Update upstream related versions

  --version, -v       Version to operate on (e.g., 1.23.0)

Optional Flags:
  --env, --environment, -e   Target environment (optional)
  --help, -h                 Show this help message and exit

Examples:
  $0 --action new-release --version 1.23.0
  $0 -a new-patch -v 1.23.0
  $0 -a new-rc -v 1.24
  $0 -a finalize-rc -v 1.24
  $0 -a update-upstream-versions -v 1.24.0

Description:
  This script automates release version operations. It will call different
  internal functions based on the selected action:
    - create-new-release
    - create-new-patch
    - create-new-rc
    - finalize-rc-release
    - update-upstream-versions

RC Workflow:
  1. Use 'new-release' to create initial x.y.0 release
  2. Use 'new-rc' to start RC builds (e.g., 1.24.0-RC-1)
  3. Continue using 'new-rc' to increment RC number
  4. After RC-2, 'new-rc' automatically switches to full build
  5. Use 'finalize-rc' to manually drop RC suffix when ready

Note:
  During RC mode (before x.y.0), upstream component versions are automatically
  updated when higher versions are released upstream. After x.y.0 release,
  minor versions of upstream components do not auto-update.
EOF
  exit 1
}

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

if [[ -z "$ACTION"  ]]; then
  echo "Using default action $DEFAULT_ACTION!"
  ACTION=$DEFAULT_ACTION
fi
if [[ -z "$VERSION"  ]]; then
  echo "Using default version $DEFAULT_VERSION!"
  VERSION=$DEFAULT_VERSION
fi

case "$ACTION" in
  "new-release")
    create-new-release $VERSION
    ;;
  "new-patch")
    create-new-patch $VERSION
    ;;
  "new-rc")
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]] && VERSION="${VERSION}.0"
    create-new-rc $VERSION
    ;;
  "finalize-rc")
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]] && VERSION="${VERSION}.0"
    finalize-rc-release $VERSION
    ;;
  "update-upstream-versions")
    update-upstream-versions $VERSION
    ;;
  *)
    echo "Invalid action: $ACTION"
    help
    ;;
esac
