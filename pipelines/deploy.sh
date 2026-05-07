#!/usr/bin/env bash
set -euo pipefail

kubectl delete configmap image-copier-data --ignore-not-found
kubectl create configmap image-copier-data \
  --from-file=copy-images.sh \
  --from-file=stage-images.json

kubectl delete pod image-copier-pod --ignore-not-found
kubectl apply -f copier-pod.yaml
kubectl wait --for=condition=Ready pod/image-copier-pod

kubectl logs image-copier-pod -f