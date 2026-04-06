HUB_KUBECONFIG=$1
SPOKE_KUBECONFIG=$2
#TEKTON_VERSION=v1.10.2

export HUB=hub
export SPOKE=spoke-1

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
#ROOT="$(dirname "$SCRIPT_DIR")"


echo "Create Hub Secret"
kubectl create secret generic ${HUB}-secret \
  --from-file=kubeconfig=${HUB_KUBECONFIG} --dry-run=client -o yaml | kubectl apply -f -

echo "Create Spoke Secret"
kubectl create secret generic ${SPOKE}-secret \
  --from-file=kubeconfig=${SPOKE_KUBECONFIG} --dry-run=client -o yaml  | kubectl apply -f -

#echo "Install Tekton Pipelines"
#	kubectl apply --server-side -f https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_VERSION}/release.yaml
#	kubectl wait --for=condition=Available deployment --all -n tekton-pipelines --timeout=300s

echo "Apply Resources"
kubectl apply -f "${SCRIPT_DIR}/tasks"

echo "Create PipelineRun"
kubectl create -f "${SCRIPT_DIR}/pipelinerun"

echo "Wait for pipeline run"
tkn pr logs -f --last