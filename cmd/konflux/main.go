package main

import (
	"embed"
	"flag"
	"fmt"
	"log"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"text/template"

	k "github.com/openshift-pipelines/hack/internal/konflux"
	"gopkg.in/yaml.v2"
)

var nameFieldInvalidCharPattern = regexp.MustCompile("[^a-z0-9]")

//go:embed templates/konflux/*.yaml templates/github/*/*.yaml templates/tekton/*.yaml
var templateFS embed.FS

func main() {
	config := flag.String("config", filepath.Join("config", "konflux", "repository.yaml"), "specify the repository configuration")
	target := flag.String("target", ".", "Target folder to generate files in")
	flag.Parse()

	in, err := os.ReadFile(*config)
	if err != nil {
		log.Fatalln(err)
	}
	c := &k.Config{}
	if err := yaml.UnmarshalStrict(in, c); err != nil {
		log.Fatalln("Unmarshal config", err)
	}
	mainPlatforms := c.Platforms
	if len(mainPlatforms) == 0 {
		mainPlatforms = []string{"linux/x86_64", "linux-m2xlarge/arm64"}
	}

	app := k.Application{
		Name:           c.Repository,
		Repository:     path.Join("openshift-pipelines", c.Repository),
		Upstream:       c.Upstream,
		Components:     c.Components,
		Branch:         "main",
		UpstreamBranch: "main",
		Version:        "main",
		GitHub:         c.GitHub,
		Tekton:         c.Tekton,
		Patches:        c.Patches,
		Platforms:      mainPlatforms,
	}

	log.Println("Generate configurations for main branch")
	if err := generateKonflux(app, filepath.Join(*target, ".konflux")); err != nil {
		log.Fatalln(err)
	}
	if err := generateGitHub(app, filepath.Join(*target, ".github")); err != nil {
		log.Fatalln(err)
	}
	if err := generateTekton(app, filepath.Join(*target, ".tekton")); err != nil {
		log.Fatalln(err)
	}
	for _, branch := range c.Branches {
		log.Printf("Generate configurations for %s branch\n", branch.Version)

		version := branch.Version
		if version != "next" {
			version = fmt.Sprintf("release-v%s.x", branch.Version)
		}

		b := version
		if branch.Upstream == "" && branch.Branch != "" {
			b = branch.Branch
		}
		platforms := branch.Platforms
		if len(platforms) == 0 {
			platforms = mainPlatforms
		}

		app := k.Application{
			Name:           c.Repository,
			Repository:     path.Join("openshift-pipelines", c.Repository),
			Upstream:       c.Upstream,
			Components:     c.Components,
			Branch:         b,
			GitHub:         c.GitHub,
			UpstreamBranch: branch.Upstream,
			Version:        branch.Version,
			Patches:        branch.Patches,
			Platforms:      platforms,
			ReleasePlan:    (branch.Release == "auto"),
		}
		if err := generateKonflux(app, filepath.Join(*target, ".konflux")); err != nil {
			log.Fatalln(err)
		}
		if err := generateGitHub(app, filepath.Join(*target, ".github")); err != nil {
			log.Fatalln(err)
		}
		if err := generateTekton(app, filepath.Join(*target, ".konflux", "tekton", branch.Version, ".tekton")); err != nil {
			log.Fatalln(err)
		}
	}
}

func generateTekton(application k.Application, target string) error {
	log.Printf("Generate tekton manifest in %s\n", target)
	if err := os.MkdirAll(target, 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(target, "docker-build-ta.yaml")); os.IsNotExist(err) {
		// Create the pipeline if it doesn't exists, otherwise, keep is as is.
		if err := generateFileFromTemplate("docker-build-ta.yaml", application, filepath.Join(target, "docker-build-ta.yaml")); err != nil {
			return err
		}
	}

	// set defaults
	if application.Tekton.WatchedSources == "" {
		application.Tekton.WatchedSources = `"upstream/***".pathChanged() || ".konflux/patches/***".pathChanged() || ".konflux/rpms/***".pathChanged()`
	}

	for _, c := range application.Components {
		component := k.Component{
			Name:        c,
			Application: application.Name,
			Repository:  application.Repository,
			Branch:      application.Branch,
			Version:     application.Version,
			Tekton:      application.Tekton,
			Platforms:   application.Platforms,
		}
		switch application.Tekton.EventType {
		case "pull_request":
			if err := generateFileFromTemplate("component-pull-request.yaml", component, filepath.Join(target, fmt.Sprintf("%s-%s-%s-pull-request.yaml", hyphenize(basename(application.Repository)), hyphenize(application.Version), c))); err != nil {
				return err
			}
		case "push":
			if err := generateFileFromTemplate("component-push.yaml", component, filepath.Join(target, fmt.Sprintf("%s-%s-%s-push.yaml", hyphenize(basename(application.Repository)), hyphenize(application.Version), c))); err != nil {
				return err
			}
		default:
			if err := generateFileFromTemplate("component-pull-request.yaml", component, filepath.Join(target, fmt.Sprintf("%s-%s-%s-pull-request.yaml", hyphenize(basename(application.Repository)), hyphenize(application.Version), c))); err != nil {
				return err
			}
			if err := generateFileFromTemplate("component-push.yaml", component, filepath.Join(target, fmt.Sprintf("%s-%s-%s-push.yaml", hyphenize(basename(application.Repository)), hyphenize(application.Version), c))); err != nil {
				return err
			}
		}
	}
	return nil
}

func generateKonflux(application k.Application, target string) error {
	log.Printf("Generate konflux manifest in %s\n", target)
	if err := os.MkdirAll(filepath.Join(target, application.Version), 0o755); err != nil {
		return err
	}
	if err := generateFileFromTemplate("application.yaml", application, filepath.Join(target, application.Version, "application.yaml")); err != nil {
		return err
	}
	if err := generateFileFromTemplate("tests.yaml", application, filepath.Join(target, application.Version, "tests.yaml")); err != nil {
		return err
	}
	if err := generateFileFromTemplate("tests-on-push.yaml", application, filepath.Join(target, application.Version, "tests-on-push.yaml")); err != nil {
		return err
	}
	if application.ReleasePlan {
		if err := generateFileFromTemplate("release-plan.yaml", application, filepath.Join(target, application.Version, "release-plan.yaml")); err != nil {
			return err
		}
	}
	for _, c := range application.Components {
		if err := generateFileFromTemplate("component.yaml", k.Component{
			Name:        c,
			Application: application.Name,
			Repository:  application.Repository,
			Branch:      application.Branch,
			Version:     application.Version,
		}, filepath.Join(target, application.Version, fmt.Sprintf("component-%s.yaml", c))); err != nil {
			return err
		}
		if err := generateFileFromTemplate("image.yaml", k.Component{
			Name:        c,
			Application: application.Name,
			Repository:  application.Repository,
			Branch:      application.Branch,
			Version:     application.Version,
		}, filepath.Join(target, application.Version, fmt.Sprintf("image-%s.yaml", c))); err != nil {
			return err
		}
	}
	return nil
}

func generateGitHub(application k.Application, target string) error {
	log.Printf("Generate github manifests in %s\n", target)
	if err := os.MkdirAll(filepath.Join(target, "workflows"), 0o755); err != nil {
		return err
	}
	if application.Upstream != "" {
		// Only generate the github workflows if there is an upstream
		filename := fmt.Sprintf("update-sources.%s.yaml", application.Version)
		if err := generateFileFromTemplate("update-sources.yaml", application, filepath.Join(target, "workflows", filename)); err != nil {
			return err
		}
	}
	amfilename := fmt.Sprintf("auto-merge.%s.yaml", application.Version)
	if err := generateFileFromTemplate("auto-merge.yaml", application, filepath.Join(target, "workflows", amfilename)); err != nil {
		return err
	}
	return nil
}

func generateFileFromTemplate(templateFile string, o interface{}, filepath string) error {
	tmpl, err := template.New(templateFile).Funcs(template.FuncMap{
		"hyphenize": hyphenize,
		"basename":  basename,
		"indent":    indent,
		"contains":  strings.Contains,
	}).ParseFS(templateFS, "templates/*/*.yaml", "templates/*/*/*.yaml")
	if err != nil {
		return err
	}
	f, err := os.Create(filepath)
	if err != nil {
		return err
	}
	defer f.Close()
	err = tmpl.Execute(f, o)
	if err != nil {
		return err
	}
	return nil
}

func hyphenize(str string) string {
	return nameFieldInvalidCharPattern.ReplaceAllString(str, "-")
}

func basename(str string) string {
	return path.Base(str)
}

func indent(spaces int, v string) string {
	pad := strings.Repeat(" ", spaces)
	return pad + strings.Replace(v, "\n", "\n"+pad, -1)
}

type arrayFlags []string

// String is an implementation of the flag.Value interface
func (i *arrayFlags) String() string {
	return fmt.Sprintf("%v", *i)
}

// Set is an implementation of the flag.Value interface
func (i *arrayFlags) Set(value string) error {
	*i = append(*i, value)
	return nil
}

// Local Variables:
// compile-command: "go run . -target /tmp/foo -config ../../config/konflux/operator.yaml"
// End:
