#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"
KONFLUX_YAML="$ROOT/config/downstream/konflux.yaml"
REPO_DIR="$ROOT/config/downstream/repos/"

function create-new-release() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch $RELEASE_YAML


  # If version already exists then no action required
  exists=$(yq e ".versions[] | select(. == \"$RELEASE_VERSION\")" "$KONFLUX_YAML")
  if [[ -n "$exists" ]]; then
    echo "Version $RELEASE_VERSION already exists. Skipping..."
    exit 0
  fi

  # Add New version in konflux.yaml
  yq -i e ".versions += \"$RELEASE_VERSION\"" $KONFLUX_YAML

  #Add Release name in $RELEASE_YAML
  yq -i e ".version = \"$RELEASE_VERSION\"" $RELEASE_YAML
  yq -i e ".image-suffix = \"-rhel9\"" $RELEASE_YAML
  create-new-patch $RELEASE_VERSION
  update-upstream-versions $RELEASE_VERSION
}


function create-new-patch(){
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"

  if [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    patch_version=$(yq ".patch-version" $RELEASE_YAML)
    echo "Current Patch Version $patch_version"
    if [[ -z "$patch_version" || "$patch_version" == "null" ]]; then
      next_version="${RELEASE_VERSION}.0"
    else
      next_version=$(echo "$patch_version" | awk -F. '{printf "%d.%d.%d\n", $1, $2, $3+1}')
    fi
  else
      next_version="$RELEASE_VERSION"
  fi
  echo "next patch Version: $next_version"
  yq -i e ".patch-version = \"$next_version\"" $RELEASE_YAML
}

update-upstream-versions() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch $RELEASE_YAML
  echo "Updating upstream version for release : $RELEASE_VERSION in $RELEASE_YAML"

  for file in "$REPO_DIR"/*.yaml; do
    [ -e "$file" ] || continue  # Skip if no files

    # Extract values with yq
    downstream="$(basename "$file" .yaml)"
    upstream=$(yq e '.upstream' "$file")
    UsePatchBranch=$(yq e '.use-patch-branch' "$file")
    # Skip when upstream is empty
    [ "$upstream" = "null" ] && upstream=""
    if [ -z "$upstream" ]; then
      continue
    fi

    echo "Upstream: $upstream, Downstream: $downstream"
    if LATEST=$(gh release view --repo $upstream --json tagName -q .tagName 2>/dev/null); then
      echo "Latest release for $upstream : $LATEST"
    else
      echo "⚠ No releases found for $upstream"
      continue
    fi
    echo "UsePatchBranch : $UsePatchBranch"
    if [[ "$UsePatchBranch" == "true" ]]; then
      BRANCH="release-${LATEST}"
    else
      BRANCH="release-${LATEST%.*}.x"
    fi
    yq -i e ".branches.$downstream.upstream = \"$BRANCH\"" $RELEASE_YAML
  done
}




