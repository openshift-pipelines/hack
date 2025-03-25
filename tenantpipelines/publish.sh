                #!/usr/bin/env bash
                set -eo pipefail
                release=$(params.RELEASED_VERSION)
                snapshot=$(params.SNAPSHOT)
                echo "Released Version : release"

                file="/tmp/snapshot.json"
                TARGET_REGISTRY="quay.io/openshift-pipeline"
                SOURCE_PATTEN="quay.io/.*/(pipeline-)?(.*@sha256:.+)"
                TARGET_PATTEN="${TARGET_REGISTRY}/pipelines-\2"
                BUNDLE_SOURCE_PATTEN="quay.io/.*/(.*)-rhel[0-9](@sha256:.+)"
                BUNDLE_TARGET_PATTEN="$TARGET_REGISTRY/pipelines-\1\2"

                get-resource "snapshot" $snapshot > $file

                component_name=$(jq '.metadata.labels."appstudio.openshift.io/component"' $file | tr -d '"')

                jq -c '.spec.components[]' /tmp/snapshot.json | while read -r component ; do
                  name=$(echo $component | jq -r .name)
                   if [[ "$name" = "$component_name"  ]]; then
                    echo "Releasing Component : $component_name"
                    container_image=$(echo $component | jq -r .containerImage)
                    if [[ $container_image =  *'operator-bundle'* ]]; then
                      new_image=$(echo "$container_image" | sed -E "s|$BUNDLE_SOURCE_PATTEN|$BUNDLE_TARGET_PATTEN|g")
                    else
                      new_image=$(echo "$container_image" | sed -E "s|$SOURCE_PATTEN|$TARGET_PATTEN|g")
                      new_image=$(echo "$new_image" | sed -E "s/operator-operator-rhel9/rhel9-operator/g")
                    fi
                    echo "Component Image updated for release : $new_image"
                    sha=${new_image/*@sha256:/}
                    new_image=${new_image/@sha256:*/}
                    tags=($release $sha)
                    for tag in "${tags[@]}"; do
                      echo "copying the image from $container_image to $new_image with tag $tag and preserving digests"
                      skopeo copy docker://"$container_image" docker://"$new_image:$tag" --all --preserve-digests
                    done
                  fi
                done