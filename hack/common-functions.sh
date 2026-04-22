#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"
KONFLUX_YAML="$ROOT/config/downstream/konflux.yaml"
REPO_DIR="$ROOT/config/downstream/repos/"

function is-rc-version() {
  local version=$1
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-RC-[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

function is-x.y.0-release() {
  local version=$1
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.0$ ]]; then
    return 0
  fi
  return 1
}

function extract-rc-number() {
  local version=$1
  echo "$version" | sed -E 's/.*-RC-([0-9]+)$/\1/'
}

function extract-base-version() {
  local version=$1
  echo "$version" | sed -E 's/-RC-[0-9]+$//'
}

function extract-minor-version() {
  local version=$1
  echo "$version" | sed -E 's/^([0-9]+\.[0-9]+)\..*/\1/'
}

function create-new-release() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch $RELEASE_YAML


  exists=$(yq e ".versions[] | select(. == \"$RELEASE_VERSION\")" "$KONFLUX_YAML")
  if [[ -n "$exists" ]]; then
    echo "Version $RELEASE_VERSION already exists. Skipping..."
    exit 0
  fi

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
  elif is-rc-version "$RELEASE_VERSION"; then
    rc_num=$(extract-rc-number "$RELEASE_VERSION")
    base_ver=$(extract-base-version "$RELEASE_VERSION")
    patch_version=$(yq ".patch-version" $RELEASE_YAML)
    if [[ -z "$patch_version" || "$patch_version" == "null" ]]; then
      next_version="${base_ver}-RC-1"
    else
      next_version=$(echo "$patch_version" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
      next_version="${next_version}-RC-${rc_num}"
    fi
  else
      next_version="$RELEASE_VERSION"
  fi
  echo "next patch Version: $next_version"
  yq -i e ".patch-version = \"$next_version\"" $RELEASE_YAML
}

function create-new-rc() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch $RELEASE_YAML

  patch_version=$(yq ".patch-version" $RELEASE_YAML)
  echo "Current Patch Version $patch_version"

  if is-rc-version "$patch_version"; then
    rc_num=$(extract-rc-number "$patch_version")
    base_ver=$(extract-base-version "$patch_version")
    if [[ $rc_num -ge 2 ]]; then
      echo "RC-$rc_num reached. Automatically switching to full release."
      yq -i e ".is-rc = false" $RELEASE_YAML
      yq -i e ".rc-number = 0" $RELEASE_YAML
      next_version="$base_ver"
    else
      next_rc=$((rc_num + 1))
      next_version="${base_ver}-RC-${next_rc}"
      yq -i e ".rc-number = $next_rc" $RELEASE_YAML
    fi
  else
    if [[ -z "$patch_version" || "$patch_version" == "null" ]]; then
      next_version="${RELEASE_VERSION}.0-RC-1"
    else
      base_ver=$(echo "$patch_version" | sed -E 's/-RC-[0-9]+$//')
      next_version="${base_ver}-RC-1"
    fi
    yq -i e ".is-rc = true" $RELEASE_YAML
    yq -i e ".rc-number = 1" $RELEASE_YAML
  fi

  echo "Next RC Version: $next_version"
  yq -i e ".patch-version = \"$next_version\"" $RELEASE_YAML
}

function finalize-rc-release() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"

  patch_version=$(yq ".patch-version" $RELEASE_YAML)

  if ! is-rc-version "$patch_version"; then
    echo "Version $patch_version is not an RC version. Nothing to finalize."
    exit 0
  fi

  base_ver=$(extract-base-version "$patch_version")
  yq -i e ".patch-version = \"$base_ver\"" $RELEASE_YAML
  yq -i e ".is-rc = false" $RELEASE_YAML
  yq -i e ".rc-number = 0" $RELEASE_YAML

  echo "Finalized RC release: $base_ver"
}

function is-auto-update-allowed() {
  local release_version=$1
  local release_yaml="$ROOT/config/downstream/releases/${release_version}.yaml"

  if [[ "$release_version" == "next" ]]; then
    return 0
  fi

  patch_version=$(yq ".patch-version" $release_yaml 2>/dev/null || echo "")

  if is-rc-version "$patch_version"; then
    return 0
  fi

  if is-x.y.0-release "$patch_version"; then
    return 1
  fi

  return 1
}

update-upstream-versions() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch $RELEASE_YAML
  echo "Updating upstream version for release : $RELEASE_VERSION in $RELEASE_YAML"

  if ! is-auto-update-allowed "$RELEASE_VERSION"; then
    echo "Auto-update of upstream versions is not allowed for this release (x.y.0 or released version)."
    echo "Skipping upstream version updates."
    return 0
  fi

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

update-upstream-versions() {
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


