package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	k "github.com/openshift-pipelines/hack/internal/konflux"
	"gopkg.in/yaml.v2"
)

const (
	GithubOrg    = "openshift-pipelines"
	baseBranchPrefix = "actions/update/dockerfile-labels-"
)

func main() {
	version := flag.String("version", "1.21", "Version for CPE label (e.g., 1.21)")
	dryRun := flag.Bool("dry-run", false, "Dry run (no commit, no PR)")
	tmpDir := flag.String("dir", "/tmp/dockerfile-labels", "folder to work in")
	flag.Parse()

	if _, err := exec.LookPath("gh"); !*dryRun && err != nil {
		log.Fatal("Couldn't find gh in your path, bailing.")
	}

	configFiles := flag.Args()
	if len(configFiles) == 0 {
		log.Fatal("No config files provided")
	}

	dir := *tmpDir
	if dir == "" {
		var err error
		dir, err = os.MkdirTemp("", "update-dockerfile-labels")
		if err != nil {
			log.Fatal(err)
		}
	}

	cpeLabel := fmt.Sprintf("cpe=\"cpe:/a:redhat:openshift_pipelines:%s::el9\"", *version)
	log.Printf("Updating Dockerfiles with CPE label: %s\n", cpeLabel)

	for _, configFile := range configFiles {
		in, err := os.ReadFile(configFile)
		if err != nil {
			log.Fatal(err)
		}
		config := k.Config{}
		if err := yaml.UnmarshalStrict(in, &config); err != nil {
			log.Fatal(err)
		}

		for _, resource := range config.Resources {
			in, err := os.ReadFile(filepath.Join(filepath.Dir(configFile), "repos", resource+".yaml"))
			if err != nil {
				log.Fatal(err)
			}
			repo := k.Repository{}
			if err := yaml.UnmarshalStrict(in, &repo); err != nil {
				log.Fatalf("Error while parsing config %s, Error: %v ", resource, err)
			}
			config.Repos = append(config.Repos, repo)
		}

		fmt.Printf("Processing repositories for %s\n", config.Name)
		if err := updateDockerfileLabels(context.Background(), config, dir, cpeLabel, *dryRun); err != nil {
			log.Fatal(err)
		}
	}
}

func updateDockerfileLabels(ctx context.Context, config k.Config, dir string, cpeLabel string, dryRun bool) error {
	for _, repo := range config.Repos {
		repository := fmt.Sprintf("https://github.com/%s/%s.git", GithubOrg, repo.Name)
		fmt.Printf("::group:: Processing repository %s\n", repository)

		for _, branch := range repo.Branches {
			checkoutDir := filepath.Join(dir, repo.Name+"-"+branch.Name)
			log.Printf("Processing %s (%s) on branch %s in %s\n", repo.Name, repository, branch.Name, checkoutDir)

			// Create checkout directory
			if err := os.MkdirAll(checkoutDir, os.ModePerm); err != nil {
				return err
			}

			// Clone and checkout branch
			if err := cloneAndCheckout(ctx, repository, branch.Name, checkoutDir, config); err != nil {
				return err
			}

			// Find and update Dockerfiles
			dockerfilesDir := filepath.Join(checkoutDir, ".konflux", "dockerfiles")
			if _, err := os.Stat(dockerfilesDir); os.IsNotExist(err) {
				log.Printf("No .konflux/dockerfiles directory found in %s, skipping\n", repo.Name)
				continue
			}

			updated := false
			dockerfiles, err := filepath.Glob(filepath.Join(dockerfilesDir, "*.Dockerfile"))
			if err != nil {
				return fmt.Errorf("failed to find Dockerfiles: %w", err)
			}

			for _, dockerfile := range dockerfiles {
				log.Printf("Updating %s\n", dockerfile)
				if err := updateDockerfileLabel(dockerfile, cpeLabel); err != nil {
					log.Printf("Warning: failed to update %s: %v\n", dockerfile, err)
				} else {
					updated = true
				}
			}

			if !updated {
				log.Printf("No Dockerfiles updated in %s\n", repo.Name)
				continue
			}

			// Commit and create PR
			if !dryRun {
				if err := commitAndPullRequest(ctx, checkoutDir, branch.Name, config, cpeLabel); err != nil {
					return err
				}
			}
		}
		fmt.Printf("::endgroup::\n")
	}
	return nil
}

func updateDockerfileLabel(dockerfilePath, cpeLabel string) error {
	content, err := os.ReadFile(dockerfilePath)
	if err != nil {
		return err
	}

	lines := strings.Split(string(content), "\n")
	
	// First, validate that the Dockerfile has a LABEL block with "name" key
	hasLabelBlock := false
	hasNameKey := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "LABEL") {
			hasLabelBlock = true
		}
		if strings.Contains(line, "name=") && (strings.HasPrefix(trimmed, "name=") || strings.Contains(line, "\"name=")) {
			hasNameKey = true
		}
	}
	
	if !hasLabelBlock {
		return fmt.Errorf("no LABEL block found in Dockerfile")
	}
	
	if !hasNameKey {
		log.Printf("WARNING: Dockerfile %s does not have 'name' key in LABEL block", dockerfilePath)
		return fmt.Errorf("LABEL block missing required 'name' key")
	}
	
	// Get the latest UBI9 minimal image digest
	latestUbi9Digest, err := getLatestUbi9Digest()
	if err != nil {
		log.Printf("WARNING: Failed to get latest UBI9 digest: %v. Skipping base image update.", err)
	}
	
	updatedLines := []string{}
	labelExists := false
	inLabelBlock := false
	labelBlockEnd := -1
	
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		
		// Update UBI9 base image if found (skip GO_BUILDER)
		if strings.HasPrefix(trimmed, "ARG RUNTIME=") && strings.Contains(line, "ubi9/ubi-minimal") && latestUbi9Digest != "" {
			// Extract the part before @sha256
			parts := strings.Split(line, "@sha256:")
			if len(parts) == 2 {
				// Replace with new digest
				updatedLines = append(updatedLines, parts[0]+"@"+latestUbi9Digest)
				continue
			}
		}
		
		// Check if this line contains CPE label already
		if strings.Contains(line, "cpe=") {
			// Replace existing CPE label
			if strings.HasPrefix(trimmed, "LABEL") {
				updatedLines = append(updatedLines, "LABEL "+cpeLabel)
			} else {
				// Part of multi-line LABEL, replace just this line
				indent := strings.Repeat(" ", len(line)-len(trimmed))
				updatedLines = append(updatedLines, indent+cpeLabel)
			}
			labelExists = true
			continue
		}
		
		// Track if we're in a LABEL block
		if strings.HasPrefix(trimmed, "LABEL") {
			inLabelBlock = true
		}
		
		// Check if this is the end of a multi-line LABEL block
		if inLabelBlock {
			// If line doesn't end with backslash, this is the end of the LABEL block
			if !strings.HasSuffix(trimmed, "\\") && trimmed != "" {
				labelBlockEnd = i
				inLabelBlock = false
			}
		}
		
		updatedLines = append(updatedLines, line)
	}

	// If label doesn't exist, append to the last LABEL block found
	if !labelExists {
		if labelBlockEnd >= 0 {
			// Insert CPE into the existing LABEL block
			// Get indentation from previous label line
			prevLine := updatedLines[labelBlockEnd]
			indent := ""
			if strings.Contains(prevLine, "      ") {
				indent = "      "
			}
			
			// Add backslash to the previous line if it doesn't have one
			if !strings.HasSuffix(strings.TrimSpace(updatedLines[labelBlockEnd]), "\\") {
				updatedLines[labelBlockEnd] = updatedLines[labelBlockEnd] + " \\"
			}
			
			// Insert the CPE label after the last label line
			newLine := indent + cpeLabel
			updatedLines = append(updatedLines[:labelBlockEnd+1], append([]string{newLine}, updatedLines[labelBlockEnd+1:]...)...)
		} else {
			// No LABEL block found, add at the end
			if len(updatedLines) > 0 && updatedLines[len(updatedLines)-1] == "" {
				updatedLines = updatedLines[:len(updatedLines)-1]
			}
			updatedLines = append(updatedLines, "", "LABEL "+cpeLabel)
		}
	}

	newContent := strings.Join(updatedLines, "\n")
	return os.WriteFile(dockerfilePath, []byte(newContent), 0644)
}

func cloneAndCheckout(ctx context.Context, repo, branch, dir string, config k.Config) error {
	branchPrefix := baseBranchPrefix + config.Name
	exists := fileExists(filepath.Join(dir, ".git"))

	if exists {
		// Repository exists, fetch the latest changes
		if out, err := run(ctx, dir, "git", "fetch", "--all"); err != nil {
			return fmt.Errorf("failed to fetch repository: %s, %s", err, out)
		}
	} else {
		// Repository does not exist, clone the repository
		if out, err := run(ctx, dir, "git", "clone", repo, "."); err != nil {
			return fmt.Errorf("failed to clone repository: %s, %s", err, out)
		}
	}

	if out, err := run(ctx, dir, "git", "reset", "--hard", "HEAD", "--"); err != nil {
		return fmt.Errorf("failed to reset %s branch: %s, %s", branch, err, out)
	}
	
	out, err := run(ctx, dir, "git", "ls-remote", "--heads", "origin", branch)
	if err != nil {
		return fmt.Errorf("failed to list remote branches: %s, %s", err, out)
	}
	
	if len(out) == 0 {
		return fmt.Errorf("branch %s does not exist in remote repository", branch)
	}
	
	if out, err := run(ctx, dir, "git", "checkout", "origin/"+branch, "-B", branch); err != nil {
		return fmt.Errorf("failed to checkout %s branch: %s, %s", branch, err, out)
	}
	
	if out, err := run(ctx, dir, "git", "checkout", "-B", branchPrefix+branch); err != nil {
		return fmt.Errorf("failed to checkout branch for PR: %s, %s", err, out)
	}
	
	return nil
}

func commitAndPullRequest(ctx context.Context, dir, branch string, config k.Config, cpeLabel string) error {
	branchPrefix := baseBranchPrefix + config.Name

	if out, err := run(ctx, dir, "git", "status", "--porcelain"); err != nil {
		return fmt.Errorf("failed to check git status: %s, %s", err, out)
	} else if string(out) == "" {
		log.Printf("[%s] No changes, skipping commit and PR", dir)
		return nil
	}
	
	if out, err := run(ctx, dir, "bash", "-c", "git config user.name openshift-pipelines-bot; git config user.email pipelines-extcomm@redhat.com"); err != nil {
		return fmt.Errorf("failed to set git configurations: %s, %s", err, out)
	}
	
	if out, err := run(ctx, dir, "git", "add", ".konflux/dockerfiles/*.Dockerfile"); err != nil {
		return fmt.Errorf("failed to add: %s, %s", err, out)
	}
	
	commitMsg := fmt.Sprintf("[bot:%s] Update Dockerfile CPE labels and base images\n\nAdd CPE label: %s\nUpdate UBI9 base image to latest", branch, cpeLabel)
	if out, err := run(ctx, dir, "git", "commit", "-m", commitMsg); err != nil {
		// Check if commit failed because there are no changes (e.g., re-run with same changes)
		if strings.Contains(string(out), "nothing to commit") {
			log.Printf("[%s] No new changes to commit", dir)
			return nil
		}
		return fmt.Errorf("failed to commit: %s, %s", err, out)
	}
	
	// Force push to update the branch (handles re-runs gracefully)
	log.Printf("[%s] Pushing changes to branch %s", dir, branchPrefix+branch)
	if out, err := run(ctx, dir, "git", "push", "-f", "origin", branchPrefix+branch); err != nil {
		return fmt.Errorf("failed to push: %s, %s", err, out)
	}
	
	// Check if PR already exists
	if out, err := run(ctx, dir, "bash", "-c", "gh pr list --base "+branch+" --head "+branchPrefix+branch+" --json number,url --jq '.[0].number'"); err != nil {
		return fmt.Errorf("failed to check if a pr exists: %s, %s", err, out)
	} else if strings.TrimSpace(string(out)) == "" {
		// PR doesn't exist, create new one
		log.Printf("[%s] Creating new PR", dir)
		prBody := fmt.Sprintf("This PR updates Dockerfile CPE labels and base images.\n\n**Changes:**\n- Label added to existing LABEL block: %s\n- Updated UBI9 base image to latest digest\n\nThis PR was automatically generated by the update-dockerfile-labels command from openshift-pipelines/hack repository", cpeLabel)
		if out, err := run(ctx, dir, "gh", "pr", "create",
			"--base", branch,
			"--head", branchPrefix+branch,
			"--label=hack", "--label=automated",
			"--title", fmt.Sprintf("[bot:%s:%s] Update Dockerfile CPE labels and base images", config.Name, branch),
			"--body", prBody); err != nil {
			return fmt.Errorf("failed to create the pr: %s, %s", err, out)
		}
	} else {
		// PR already exists, just update it via force push (already done above)
		prNumber := strings.TrimSpace(string(out))
		log.Printf("[%s] PR #%s already exists and has been updated with force push", dir, prNumber)
	}
	
	return nil
}

func run(ctx context.Context, dir string, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	return cmd.CombinedOutput()
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func getLatestUbi9Digest() (string, error) {
	// Try to get the latest digest using docker/podman
	// First try skopeo (most reliable)
	if out, err := exec.Command("skopeo", "inspect", "docker://registry.access.redhat.com/ubi9/ubi-minimal:latest").Output(); err == nil {
		var result map[string]interface{}
		if err := json.Unmarshal(out, &result); err == nil {
			if digest, ok := result["Digest"].(string); ok {
				log.Printf("Found latest UBI9 digest via skopeo: %s", digest)
				return digest, nil
			}
		}
	}
	
	// Fallback: try docker
	if out, err := exec.Command("docker", "pull", "registry.access.redhat.com/ubi9/ubi-minimal:latest").CombinedOutput(); err == nil {
		lines := strings.Split(string(out), "\n")
		for _, line := range lines {
			if strings.Contains(line, "Digest:") {
				parts := strings.Fields(line)
				if len(parts) >= 2 {
					digest := parts[len(parts)-1]
					log.Printf("Found latest UBI9 digest via docker: %s", digest)
					return digest, nil
				}
			}
		}
	}
	
	// Fallback: try podman
	if out, err := exec.Command("podman", "pull", "registry.access.redhat.com/ubi9/ubi-minimal:latest").CombinedOutput(); err == nil {
		lines := strings.Split(string(out), "\n")
		for _, line := range lines {
			if strings.Contains(line, "Digest:") {
				parts := strings.Fields(line)
				if len(parts) >= 2 {
					digest := parts[len(parts)-1]
					log.Printf("Found latest UBI9 digest via podman: %s", digest)
					return digest, nil
				}
			}
		}
	}
	
	return "", fmt.Errorf("could not determine latest UBI9 digest using skopeo, docker, or podman")
}
