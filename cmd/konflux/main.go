package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	k "github.com/openshift-pipelines-konflux/hack/internal/konflux"
	"gopkg.in/yaml.v2"
)

const (
	GithubOrg          = "openshift-pipelines-konflux"
	DefaultImageSuffix = "-rhel9"
	DefaultImagePrefix = "pipeline-"
)

func main() {
	flag.Parse()
	configFiles := flag.Args()
	configFile := "config/konflux.yaml"
	if len(configFiles) == 1 {
		configFile = configFiles[0]
	}
	configDir := filepath.Dir(configFile)

	// Read the main konflux config using the generic readResource function
	config, err := readConfig(configDir, filepath.Base(configFile))
	if err != nil {
		log.Fatal(err)
	}

	for _, version := range config.Versions {
		versionConfig, err := readResource[k.ReleaseConfig](configDir, "releases", version)
		if err != nil {
			log.Fatal(err)
		}
		versionConfig.Version.Version = version
		log.Printf("%v", versionConfig)
		for _, applicationName := range config.Applications {
			// Read application using the generic readResource function
			applications, err := readApplications(configDir, applicationName, versionConfig)
			if err != nil {
				log.Fatal(err)
			}
			for _, application := range applications {
				log.Printf("Loaded application: %s", application.Name)
				if err := k.GenerateConfig(application); err != nil {
					log.Fatal(err)
				}
			}

		}
	}

	log.Printf("Done:")
}

// readResource reads any type of resource from YAML files
func readResource[T any](dir, resourceType, resourceName string) (T, error) {
	var result T
	if !strings.HasSuffix(resourceName, ".yaml") {
		resourceName += ".yaml"
	}
	filePath := filepath.Join(dir, resourceType, resourceName)
	in, err := os.ReadFile(filePath)

	if err != nil {
		return result, err
	}

	if err := yaml.UnmarshalStrict(in, &result); err != nil {
		return result, fmt.Errorf("error while parsing config %s: %w", filePath, err)
	}

	return result, nil
}

// Helper functions using the generic readResource function
func readApplications(dir, applicationName string, versionConfig k.ReleaseConfig) ([]k.Application, error) {

	log.Printf("Reading application: %s", applicationName)
	applicationConfigs, err := readResource[[]k.ApplicationConfig](dir, "applications", applicationName)

	if err != nil {
		return []k.Application{}, err
	}
	var applications []k.Application

	for _, applicationConfig := range applicationConfigs {
		application := k.Application{
			Name:            applicationConfig.Name,
			Components:      []k.Component{},
			Release:         &versionConfig.Version,
			Org:             applicationConfig.Org,
			ReleaseToGitHub: applicationConfig.ReleaseToGitHub,
			AutoRelease:     true,
			Namespace:       applicationConfig.Namespace,
		}
		for _, repoName := range applicationConfig.Repositories {
			repo, err := readRepository(dir, repoName, &application, versionConfig.Branches[repoName])

			if err != nil {
				return []k.Application{}, err
			}
			application.Components = append(application.Components, repo.Components...)
			application.Repositories = append(application.Repositories, repo)

			log.Printf("Loaded repository: %s", repo.Name)
		}
		applications = append(applications, application)

	}
	return applications, nil
}

func updateRepository(repo *k.Repository, a k.Application) error {
	repo.Application = a
	if a.Org == "" {
		a.Org = GithubOrg
	}
	if repo.Url == "" {
		repository := fmt.Sprintf("https://github.com/%s/%s.git", a.Org, repo.Name)
		repo.Url = repository
	}

	var branchName, upstreamBranch string

	if a.Release.Version == "main" || a.Release.Version == "next" {
		branchName = "main"
		upstreamBranch = "main"
	} else {
		branchName = "release-v" + a.Release.Version + ".x"
		upstreamBranch = "main"
	}

	branch := &repo.Branch
	if branch.Name == "" {
		branch.Name = branchName
	}
	if branch.UpstreamBranch == "" {
		branch.UpstreamBranch = upstreamBranch
	}

	// Tekton
	if repo.Tekton == (k.Tekton{}) {
		repo.Tekton = k.Tekton{}
		if repo.Tekton.WatchedSources == "" {
			repo.Tekton.WatchedSources = `"upstream/***".pathChanged() || ".konflux/patches/***".pathChanged() || ".konflux/rpms/***".pathChanged()`
		}

	}

	return nil
}

// readRepository reads a repository resource from the repos directory
func readRepository(dir, repoName string, app *k.Application, branch k.Branch) (k.Repository, error) {
	repository, err := readResource[k.Repository](dir, "repos", repoName)
	if err != nil {
		return k.Repository{}, err
	}

	repository.Branch = branch
	if err := updateRepository(&repository, *app); err != nil {
		return k.Repository{}, err
	}
	for i := range repository.Components {
		if err := UpdateComponent(&repository.Components[i], repository, *app); err != nil {
			return k.Repository{}, err
		}
	}
	return repository, err
}

// UpdateComponent function can be modified  if we want to override the fields at component level.
func UpdateComponent(c *k.Component, repo k.Repository, app k.Application) error {
	log.Printf("Updating component: %s", c.Name)
	version := *app.Release

	c.Version = version
	c.Application = repo.Application
	c.Repository = repo

	if c.Tekton == (k.Tekton{}) {
		c.Tekton = repo.Tekton
	}
	if c.Dockerfile == "" {
		Dockerfile, err := k.Eval(".konflux/dockerfiles/{{.Name}}.Dockerfile", c)
		if err != nil {
			return err
		}
		c.Dockerfile = Dockerfile
	}
	if c.PrefetchInput == "" {
		c.PrefetchInput = "{\"type\": \"rpm\", \"path\": \".konflux/rpms\"}"
	}
	if version.ImageSuffix != "None" {
		c.ImageSuffix = version.ImageSuffix
		if c.ImageSuffix == "" {
			c.ImageSuffix = DefaultImageSuffix
		}
	}
	// This is the case for git-init where we don't require upstream name because comet created is pipelines-git-init-rhel8
	c.ImagePrefix = version.ImagePrefix
	if !repo.NoPrefixUpstream && repo.Upstream != "" {
		c.ImagePrefix += strings.Split(repo.Upstream, "/")[1] + "-"
	}
	//log.Printf("Using image prefix: %s", c.ImagePrefix)
	return nil
}

// readConfig reads the main konflux config file
func readConfig(dir, configFile string) (k.Config, error) {
	return readResource[k.Config](dir, "", configFile)
}
