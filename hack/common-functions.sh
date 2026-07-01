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
  update-operator-components "${RELEASE_VERSION}" latest
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
      # shellcheck disable=SC2001
      base_version=$(echo "${release_tag}" | sed "s/[0-9]\+$//")
      next_version="${base_version}$((last_num + 1))"
    fi
  else
      next_version="$RELEASE_VERSION"
  fi
  echo "next tag: $next_version"
  yq -i e ".release-tag = \"$next_version\"" "${RELEASE_YAML}"

  # Update operator components.yaml for finalized patch versions (not RCs)
  if [[ ! "$next_version" =~ -RC- ]]; then
    update-operator-components "${RELEASE_VERSION}"
  fi
}

function update-operator-components() {
  local RELEASE_VERSION=$1
  # "patch" = latest in same minor series, "latest" = absolute latest
  local MODE=${2:-patch}
  local RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"

  local operator_branch
  operator_branch=$(yq e '.branches.operator.upstream' "$RELEASE_YAML")
  if [[ -z "$operator_branch" || "$operator_branch" == "null" ]]; then
    echo "No operator branch configured in $RELEASE_YAML, skipping operator components update"
    return
  fi

  echo "Updating operator components.yaml on tektoncd/operator branch: $operator_branch (mode: $MODE)"

  local work_dir
  work_dir=$(mktemp -d)
  trap 'rm -rf "$work_dir"' RETURN

  if ! gh repo clone tektoncd/operator "$work_dir/operator" -- --branch "$operator_branch" --depth 1 2>/dev/null; then
    echo "Failed to clone tektoncd/operator branch $operator_branch"
    return
  fi

  local components_file="$work_dir/operator/components.yaml"
  if [[ ! -f "$components_file" ]]; then
    echo "components.yaml not found on branch $operator_branch"
    return
  fi

  local github_repo current_version new_version escaped_minor
  while IFS= read -r component; do
    github_repo=$(yq e ".${component}.github" "$components_file")
    current_version=$(yq e ".${component}.version" "$components_file")

    if [[ -z "$github_repo" || "$github_repo" == "null" ]]; then
      continue
    fi

    new_version=""
    if [[ "$MODE" == "latest" ]]; then
      if ! new_version=$(gh release view --repo "$github_repo" --json tagName -q .tagName 2>/dev/null); then
        echo "Could not fetch latest release for $github_repo"
        continue
      fi
    else
      escaped_minor="${current_version%.*}"
      escaped_minor="${escaped_minor//./\\.}"
      if ! new_version=$(gh release list --repo "$github_repo" --limit 20 --json tagName --jq '.[].tagName' 2>/dev/null \
          | grep "^${escaped_minor}\.[0-9]\+$" | sort -V | tail -1); then
        echo "Could not fetch releases for $github_repo"
        continue
      fi
    fi

    if [[ -n "$new_version" && "$new_version" != "$current_version" ]]; then
      echo "  $component: $current_version → $new_version"
      yq -i e ".${component}.version = \"$new_version\"" "$components_file"
    else
      echo "  $component: $current_version (up to date)"
    fi
  done < <(yq e 'keys | .[]' "$components_file")

  if git -C "$work_dir/operator" diff --quiet components.yaml; then
    echo "All operator components already at latest versions"
    return
  fi

  gh repo fork tektoncd/operator --clone=false 2>/dev/null || true

  local fork_user source_branch
  fork_user=$(gh api user --jq .login)
  source_branch="chore/bump-component-versions-${operator_branch}-$(date +%Y%m%d%H%M%S)"

  git -C "$work_dir/operator" config user.name openshift-pipelines-bot
  git -C "$work_dir/operator" config user.email pipelines-extcomm@redhat.com
  git -C "$work_dir/operator" remote add fork "https://github.com/${fork_user}/operator.git"
  git -C "$work_dir/operator" checkout -b "$source_branch"
  git -C "$work_dir/operator" add components.yaml
  git -C "$work_dir/operator" commit -m "chore: bump component versions to latest patch releases"
  git -C "$work_dir/operator" push -f fork "$source_branch"

  gh pr create \
    --repo tektoncd/operator \
    --base "$operator_branch" \
    --head "${fork_user}:${source_branch}" \
    --title "chore: bump component versions to latest patch releases" \
    --body "Automated update of component versions in components.yaml to their latest patch releases."

  echo "Operator components.yaml update PR created"
}

function update-upstream-versions() {
  RELEASE_VERSION=$1
  RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
  touch "$RELEASE_YAML"
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
    if LATEST=$(gh release view --repo "$upstream" --json tagName -q .tagName 2>/dev/null); then
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
    yq -i e ".branches.$downstream.upstream = \"$BRANCH\"" "$RELEASE_YAML"
  done
}
