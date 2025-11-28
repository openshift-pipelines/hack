#!/bin/bash
set -e
RELEASE_VERSION=${1:-next}
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT="$(dirname "$SCRIPT_DIR")"

RELEASE_YAML="$ROOT/config/downstream/releases/${RELEASE_VERSION}.yaml"
REPO_DIR="$ROOT/config/downstream/repos/"



for file in "$REPO_DIR"/*.yaml; do
  [ -e "$file" ] || continue  # Skip if no files

  # Extract values with yq
  downstream="$(basename "$file" .yaml)"
  upstream=$(yq e '.upstream' "$file")
  # Skip when upstream is empty
  [ "$upstream" = "null" ] && upstream=""
  if [ -z "$upstream" ]; then
    echo "⚠ Upstream is empty for $downstream — skipping..."
    continue
  fi


#  TAG=$(gh release view --repo $upstream --json tagName -q .tagName)
  echo "Fetching Latest Release"
  if LATEST=$(gh release view --repo $upstream --json tagName -q .tagName 2>/dev/null); then
    echo "Latest release: $LATEST"
  else
    echo "⚠ No releases found for $upstream"
    continue
  fi

  BRANCH="release-${LATEST%.*}.x"
  yq -i e ".branches.$downstream.upstream = \"$BRANCH\"" $RELEASE_YAML
done
