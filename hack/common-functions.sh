#!/bin/bash
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"
KONFLUX_YAML="$ROOT/config/downstream/konflux.yaml"
REPO_DIR="$ROOT/config/downstream/repos/"

function unfreeze-if-needed() {
  local release_yaml=$1
  local code_freeze
  code_freeze=$(yq e '.code-freeze // false' "$release_yaml")
  if [[ "$code_freeze" == "true" ]]; then
    echo "code-freeze is true, setting to false in $release_yaml"
    yq -i e '.code-freeze = false' "$release_yaml"
  fi
}

function finalize-rc-release() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"

  release_tag=$(yq ".release-tag" "${RELEASE_YAML}")

  # Only "finalize" RC versions, which have a version like "1.2.3-RC-1"
  if [[ ! "${release_tag}" =~ [0-9]+\.[0-9]+\.[0-9]+-RC-[0-9]+ ]]; then
    echo "Version $release_tag is not an RC version. Nothing to finalize."
    return
  fi

  next_version=$(echo "${release_tag}" | grep --only-matching  '^[0-9]\+\.[0-9]\+\.[0-9]\+')
  yq -i e ".release-tag = \"${next_version}\"" "${RELEASE_YAML}"

  echo "Finalized RC release: ${next_version}"
}

function create-new-release() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch "${RELEASE_YAML}"


  # If version already exists then no action required
  exists=$(yq e ".versions[] | select(. == \"$RELEASE_VERSION\")" "$KONFLUX_YAML")
  if [[ -n "$exists" ]]; then
    echo "Version $RELEASE_VERSION already exists. Skipping..."
    exit 0
  fi

  # Add New version in konflux.yaml
  #  yq -i e ".versions += \"$RELEASE_VERSION\"" $KONFLUX_YAML

  #Add Release name in $RELEASE_YAML
  yq -i e ".version = \"$RELEASE_VERSION\"" "${RELEASE_YAML}"
  yq -i e ".image-suffix = \"-rhel9\"" "${RELEASE_YAML}"
  create-new-patch "${RELEASE_VERSION}"
  update-upstream-versions "${RELEASE_VERSION}"
}

function create-new-patch() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  unfreeze-if-needed "$RELEASE_YAML"

  if [[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    release_tag=$(yq ".release-tag" "${RELEASE_YAML}")
    echo "Current tag $release_tag"
    if [[ -z "$release_tag" || "$release_tag" == "null" ]]; then
      # Always initialize a new version as x.y.0-RC-1
      next_version="${RELEASE_VERSION}.0-RC-1"
    else
      last_num=$(echo "${release_tag}" | grep --only-matching "[0-9]\+$")
      base_version=$(echo "${release_tag}" | grep -v --only-matching "[0-9]\+$")
      next_version="${base_version}$((last_num + 1))"
    fi
  else
      next_version="$RELEASE_VERSION"
  fi
  echo "next tag: $next_version"
  yq -i e ".release-tag = \"$next_version\"" "${RELEASE_YAML}"
}

function update-upstream-versions() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch $RELEASE_YAML
  unfreeze-if-needed "$RELEASE_YAML"
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


