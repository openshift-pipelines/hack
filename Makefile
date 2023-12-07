.PHONY: generate-openshift-ci
generate-openshift:
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-buildpacks.yaml $(ARGS)
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-containers.yaml $(ARGS)
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-git.yaml $(ARGS)
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-maven.yaml $(ARGS)
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-openshift.yaml $(ARGS)
