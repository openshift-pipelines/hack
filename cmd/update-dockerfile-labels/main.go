package main

import (
	"context"
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
	updatedLines := []string{}
	labelExists := false
	
	for _, line := range lines {
		// Check if line contains CPE label
		if strings.Contains(line, "LABEL") && strings.Contains(line, "cpe=") {
			// Replace existing CPE label
			updatedLines = append(updatedLines, "LABEL "+cpeLabel)
			labelExists = true
		} else {
			updatedLines = append(updatedLines, line)
		}
	}

	// If label doesn't exist, add it at the end
	if !labelExists {
		// Remove empty trailing line if exists
		if len(updatedLines) > 0 && updatedLines[len(updatedLines)-1] == "" {
			updatedLines = updatedLines[:len(updatedLines)-1]
		}
		updatedLines = append(updatedLines, "", "LABEL "+cpeLabel)
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
	
	commitMsg := fmt.Sprintf("[bot:%s] Update Dockerfile CPE labels\n\nAdd CPE label: %s", branch, cpeLabel)
	if out, err := run(ctx, dir, "git", "commit", "-m", commitMsg); err != nil {
		return fmt.Errorf("failed to commit: %s, %s", err, out)
	}
	
	if out, err := run(ctx, dir, "git", "push", "-f", "origin", branchPrefix+branch); err != nil {
		return fmt.Errorf("failed to push: %s, %s", err, out)
	}
	
	if out, err := run(ctx, dir, "bash", "-c", "gh pr list --base "+branch+" --head "+branchPrefix+branch+" --json url --jq 'length'"); err != nil {
		return fmt.Errorf("failed to check if a pr exists: %s, %s", err, out)
	} else if strings.TrimSpace(string(out)) == "0" {
		prBody := fmt.Sprintf("This PR updates Dockerfile CPE labels.\n\nLabel added: %s\n\nThis PR was automatically generated by the update-dockerfile-labels command from openshift-pipelines/hack repository", cpeLabel)
		if out, err := run(ctx, dir, "gh", "pr", "create",
			"--base", branch,
			"--head", branchPrefix+branch,
			"--label=hack", "--label=automated",
			"--title", fmt.Sprintf("[bot:%s:%s] Update Dockerfile CPE labels", config.Name, branch),
			"--body", prBody); err != nil {
			return fmt.Errorf("failed to create the pr: %s, %s", err, out)
		}
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
