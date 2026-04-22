package konflux

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func MutateDockerFile(component Component, repoDir string) error {

	newArgs := getArgs(component)
	newLabels := getDockerFileLabels(component)

	dockerfile := filepath.Join(repoDir, component.Dockerfile)
	data, err := os.ReadFile(dockerfile)
	if err != nil {
		return err
	}

	lines := strings.Split(string(data), "\n")

	labels := map[string]string{}

	var labelStart = -1
	var labelEnd = -1

	for i := range lines {

		trim := strings.TrimSpace(lines[i])

		// ------------------
		// Update ARG
		// ------------------
		if strings.HasPrefix(trim, "ARG ") {

			arg := strings.TrimPrefix(trim, "ARG ")
			parts := strings.SplitN(arg, "=", 2)

			if len(parts) == 2 {

				name := strings.TrimSpace(parts[0])

				if v, ok := newArgs[name]; ok {
					lines[i] = fmt.Sprintf("ARG %s=%s", name, v)
				}
			}
		}

		// ------------------
		// Detect LABEL block
		// ------------------
		if strings.HasPrefix(trim, "LABEL") {

			if labelStart == -1 {
				labelStart = i
			}

			labelEnd = i

			line := trim

			for strings.HasSuffix(line, "\\") {

				labelEnd++

				if labelEnd >= len(lines) {
					break
				}

				line = strings.TrimSpace(lines[labelEnd])
			}
		}
	}

	// ------------------
	// Extract label values
	// ------------------
	if labelStart >= 0 {

		for _, line := range lines[labelStart : labelEnd+1] {

			l := strings.TrimSpace(line)
			l = strings.TrimPrefix(l, "LABEL")
			l = strings.TrimSuffix(l, "\\")
			l = strings.TrimSpace(l)

			if l == "" {
				continue
			}

			parts := strings.SplitN(l, "=", 2)

			if len(parts) == 2 {

				k := strings.TrimSpace(parts[0])
				v := strings.Trim(parts[1], `"`)

				if k != "" {
					labels[k] = v
				}
			}
		}
	}

	// ------------------
	// Merge labels
	// ------------------
	for k, v := range newLabels {
		labels[k] = v
	}

	// ------------------
	// Sort labels
	// ------------------
	keys := make([]string, 0, len(labels))

	for k := range labels {
		keys = append(keys, k)
	}

	sort.Strings(keys)

	// ------------------
	// Build LABEL block
	// ------------------
	var labelBlock []string

	labelBlock = append(labelBlock, "LABEL \\")

	for i, k := range keys {

		v := labels[k]

		if i == len(keys)-1 {
			labelBlock = append(labelBlock,
				fmt.Sprintf("    %s=\"%s\"", k, v))
		} else {
			labelBlock = append(labelBlock,
				fmt.Sprintf("    %s=\"%s\" \\", k, v))
		}
	}

	// ------------------
	// Replace LABEL block
	// ------------------
	var result []string

	if labelStart >= 0 {

		result = append(result, lines[:labelStart]...)
		result = append(result, labelBlock...)
		result = append(result, lines[labelEnd+1:]...)

	} else {

		result = append(lines, "")
		result = append(result, labelBlock...)
	}

	// ------------------
	// Write file
	// ------------------
	return os.WriteFile(dockerfile, []byte(strings.Join(result, "\n")), 0644)
}
func getArgs(component Component) map[string]string {
	return map[string]string{
		"GO_BUILDER": "registry.access.redhat.com/ubi9/go-toolset:1.25",
		"RUNTIME":    "registry.access.redhat.com/ubi9/ubi-minimal:latest",
		"VERSION":    component.Version.Version,
	}
}

func getDockerFileLabels(component Component) map[string]string {
	// Define your dynamic updates here
	labels := map[string]string{
		"com.redhat.component": fmt.Sprintf("openshift-%s-container", component.Image),
		"name":                 fmt.Sprintf("openshift-pipelines/%s", component.Image),
		"version":              component.Version.PatchVersion,
		"maintainer":           "pipelines-extcomm@redhat.com",
		"summary":              fmt.Sprintf("Red Hat OpenShift Pipelines %s %s", component.Repository.Name, component.Name),
		"description":          fmt.Sprintf("Red Hat OpenShift Pipelines %s %s", component.Repository.Name, component.Name),
		"io.k8s.description":   fmt.Sprintf("Red Hat OpenShift Pipelines %s %s", component.Repository.Name, component.Name),
		"io.k8s.display-name":  fmt.Sprintf("Red Hat OpenShift Pipelines %s %s", component.Repository.Name, component.Name),
		"io.openshift.tags":    fmt.Sprintf("tekton,openshift,%s,%s", component.Repository.Name, component.Name),
		"cpe":                  fmt.Sprintf("cpe:/a:redhat:openshift_pipelines:%s::el9", component.Version.Version),
		// Add any others here...
	}

	return labels
}
