#!/usr/bin/env bash
set -euo pipefail

# ─── Dependencies check ───────────────────────────────────────────────────────
for cmd in skopeo jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "❌ Required tool not found: $cmd"
    exit 1
  fi
done

# ─── Args ─────────────────────────────────────────────────────────────────────
JSON_FILE="${1:-images.json}"
TAG="${2:-}"
DEST_REGISTRY="${3:-quay.io/openshift-pipeline}"

if [[ ! -f "$JSON_FILE" ]]; then
  echo "❌ JSON file not found: $JSON_FILE"
  echo "Usage: $0 <path-to-json> <tag> [dest-registry]"
  echo "Example: $0 images.json 1-22-stage"
  exit 1
fi

if [[ -z "$TAG" ]]; then
  echo "❌ Tag is required"
  echo "Usage: $0 <path-to-json> <tag> [dest-registry]"
  echo "Example: $0 images.json 1-22-stage"
  exit 1
fi

echo "🚀 Starting image copy"
echo "   Tag:          ${TAG}"
echo "   Registry:     ${DEST_REGISTRY}"
echo "   Config:       ${JSON_FILE}"
echo "──────────────────────────────────────────────────"

# ─── Track results ────────────────────────────────────────────────────────────
SUCCESS=()
FAILED=()

# ─── Loop over versions ───────────────────────────────────────────────────────
while IFS="=" read -r version src; do
  # Strip leading 'v' from version: v4.21 → 4.21
  ocp_version="${version#v}"

  # Build repo name and destination: pipelines-index-4.21:1-22-stage
  dest_repo="pipelines-index-${ocp_version}"
  dest="docker://${DEST_REGISTRY}/${dest_repo}:${TAG}"

  echo ""
  echo "📦 Copying ${version}"
  echo "   SRC:  ${src}"
  echo "   DEST: ${dest}"

  cmd="skopeo copy --all \
              docker://${src} \
              ${dest}"
  echo $cmd
  if eval $cmd ; then
    echo "   ✅ Success: ${version}"
    SUCCESS+=("${dest}")
  else
    echo "   ❌ Failed:  ${version}"
    FAILED+=("$version")
  fi

done < <(jq -r '.index_image | to_entries[] | "\(.key)=\(.value.index_image_resolved)"' "$JSON_FILE")

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════"
echo "📊 Summary"
echo "══════════════════════════════════════════════════"
echo ">> ✅ Succeeded (${#SUCCESS[@]})"
printf "%s\n"  "${SUCCESS[@]#docker://}"

echo ">> ❌ Failed    (${#FAILED[@]})"
printf "%s  \n"  "${FAILED[@]}"

[[ ${#FAILED[@]} -eq 0 ]] && exit 0 || exit 1