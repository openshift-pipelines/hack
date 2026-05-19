#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"
KONFLUX_YAML="$ROOT/config/downstream/konflux.yaml"
REPO_DIR="$ROOT/config/downstream/repos/"

function finalize-rc-release() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"

  patch_version=$(yq ".patch-version" "${RELEASE_YAML}")
  is_rc=$(yq '.is-rc' "${RELEASE_YAML}")

  if [[ "${is_rc}" != "true" ]]; then
    echo "Version $patch_version is not an RC version. Nothing to finalize."
    return
  fi

  yq -i e ".is-rc = false" "${RELEASE_YAML}"
  yq -i e "del(.rc-number)" "${RELEASE_YAML}"

  echo "Finalized RC release: ${patch_version}"
}

function create-new-rc() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"

  # Only create new release if file doesn't exist
  if [[ ! -f "${RELEASE_YAML}" ]]; then
    create-new-release "$@"
  fi

  is_rc=$(yq ".is-rc" "${RELEASE_YAML}")
  patch_version=$(yq ".patch-version" "${RELEASE_YAML}")
  echo "Current RC version $patch_version"

  # Bump the RC version for existing RC builds
  if [[ "$is_rc" == "true" ]]; then
    rc_num=$(yq ".rc-number" "${RELEASE_YAML}")
    if [[ $rc_num -ge 2 ]]; then
      echo "RC-$rc_num reached. Automatically switching to full release."
      finalize-rc-release "$@"
      return
    else
      next_rc=$((rc_num + 1))
    fi
  else
    # If is-rc is explicitly false, it's already been finalized
    if [[ "$is_rc" == "false" ]]; then
      echo "RC for ${patch_version} already finalized, skipping"
      return
    fi
    yq -i e ".is-rc = true" "${RELEASE_YAML}"
    next_rc=1
  fi

  yq -i e ".rc-number = $next_rc" "${RELEASE_YAML}"

  echo "Next RC Version: ${patch_version}-RC-${next_rc}"
}

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
#  yq -i e ".versions += \"$RELEASE_VERSION\"" $KONFLUX_YAML

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

function update-upstream-versions() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch $RELEASE_YAML
  echo "Updating upstream version for release : $RELEASE_VERSION in $RELEASE_YAML"

  for file in "$REPO_DIR"/*.yaml; do
    [ -e "$file" ] || continue # Skip if no files

    downstream="$(basename "$file" .yaml)"
    upstream=$(yq e '.upstream' "$file")
    UsePatchBranch=$(yq e '.use-patch-branch' "$file")
    [ "$upstream" = "null" ] && upstream=""
    if [[ -z "$upstream" || "$upstream" == "tektoncd/operator" ]]; then
      continue
    fi

    echo "Downstream: $downstream , Upstream: $upstream"
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


