.PHONY: generate-openshift-ci update

generate-openshift:
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-buildpacks.yaml $(ARGS)
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-containers.yaml $(ARGS)
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-git.yaml $(ARGS)
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-maven.yaml $(ARGS)
	go run github.com/openshift-pipelines/hack/cmd/prowgen --config config/task-openshift.yaml $(ARGS)

# Simple command to update all configurations - just provide the version number
# Usage: make update VERSION=1.16 [DRY_RUN=--dry-run]
update:
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: Missing VERSION parameter. Usage:"; \
		echo "  make update VERSION=1.16 [DRY_RUN=--dry-run]"; \
		exit 1; \
	fi
	./hack/update-all.sh $(DRY_RUN) $(VERSION)

# Help target
help:
	@echo "Available targets:"
	@echo "  generate-openshift          - Generate OpenShift CI configuration"
	@echo "  update                      - Update all configurations with version number"
	@echo "  help                        - Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make update VERSION=1.16 [DRY_RUN=--dry-run]"
	@echo ""
	@echo "Add DRY_RUN=--dry-run to any command to see what would be changed without making changes"
