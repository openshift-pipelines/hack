#!/usr/bin/env bash
OWNER=openshift-pipelines
RELEASE=${1:-1.18.0}
TAG_NAME=osp-v$RELEASE
echo $RELEASE


for RELEASE_FILE in $RELEASE/prod/*; do
  if [[ "$(basename "$RELEASE_FILE")" != operator-fbc* ]]; then
      echo "Creating tag from release file: $RELEASE_FILE"
      SNAPSHOT=$(yq .spec.snapshot $RELEASE_FILE)
      REPO=$(yq '.metadata.labels["pac.test.appstudio.openshift.io/url-repository"]' $RELEASE_FILE)
      echo "Snapshot being used for REPO $REPO is : $SNAPSHOT"

      COMMIT_SHA=$(oc get snapshot $SNAPSHOT -o jsonpath="{.metadata.labels.pac\.test\.appstudio\.openshift\.io\/sha}")
      if [[ -z "$COMMIT_SHA" ]]; then
       COMMIT_SHA=$(oc get snapshot $SNAPSHOT -o jsonpath="{.spec.components[0].source.git.revision}")
      fi
      echo "Commit SHA for $REPO is : $COMMIT_SHA"

      # Check if the tag exists
      EXISTING_TAG=$(gh api repos/$OWNER/$REPO/git/refs/tags/$TAG_NAME --jq .ref 2>/dev/null || echo "")

      if [[ -n "$EXISTING_TAG" ]]; then
        echo "$EXISTING_TAG : Tag $TAG_NAME already exists. Updating it..."
        # Delete the existing tag reference
        gh api repos/$OWNER/$REPO/git/refs/tags/$TAG_NAME -X DELETE
      fi


      #Create Tag Object
      TAG_SHA=$(gh api repos/$OWNER/$REPO/git/tags \
        -X POST \
        -F tag="$TAG_NAME" \
        -F message="Release Tag for $RELEASE" \
        -F object="$COMMIT_SHA" \
        -F type="commit" --jq .sha)

      #Create Tag now
      gh api repos/$OWNER/$REPO/git/refs \
        -X POST \
        -F ref="refs/tags/$TAG_NAME" \
        -F sha="$TAG_SHA"
  fi
done



