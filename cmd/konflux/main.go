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
	"text/template"

	"gopkg.in/yaml.v2"
)

var nameFieldInvalidCharPattern = regexp.MustCompile("[^a-z0-9]")

//go:embed templates/konflux/*.yaml templates/github/*/*.yaml templates/tekton/*.yaml
var templateFS embed.FS

type Application struct {
	Name           string
	Repository     string
	Upstream       string
	Branch         string
	UpstreamBranch string
	Components     []string
}

type Component struct {
	Name        string
	Application string
	Repository  string
	Branch      string
}

type Config struct {
	Repository string
	Upstream   string
	Components []string
	Branches   []Branch
}

type Branch struct {
	Version  string
	Upstream string
}

func main() {
	config := flag.String("config", filepath.Join("config", "konflux", "repository.yaml"), "specify the repository configuration")
	target := flag.String("target", ".", "Target folder to generate files in")
	flag.Parse()

	in, err := os.ReadFile(*config)
	if err != nil {
		log.Fatalln(err)
	}
	c := &Config{}
	if err := yaml.UnmarshalStrict(in, c); err != nil {
		log.Fatalln("Unmarshal config", err)
	}

	app := Application{
		Name:           c.Repository,
		Repository:     path.Join("openshift-pipelines", c.Repository),
		Upstream:       c.Upstream,
		Components:     c.Components,
		Branch:         "main",
		UpstreamBranch: "main",
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

		app := Application{
			Name:           c.Repository,
			Repository:     path.Join("openshift-pipelines", c.Repository),
			Upstream:       c.Upstream,
			Components:     c.Components,
			Branch:         fmt.Sprintf("release-v%s.x", branch.Version),
			UpstreamBranch: branch.Upstream,
		}
		if err := generateKonflux(app, filepath.Join(*target, ".konflux")); err != nil {
			log.Fatalln(err)
		}
		if err := generateGitHub(app, filepath.Join(*target, ".github")); err != nil {
			log.Fatalln(err)
		}

		// if err := generateTekton(app, filepath.Join(*target, ".tekton")); err != nil {
		// 	log.Fatalln(err)
		// }
	}
}

func generateTekton(application Application, target string) error {
	log.Printf("Generate tekton manifest in %s\n", target)
	if err := os.MkdirAll(target, 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(target, "docker-build.yaml")); os.IsNotExist(err) {
		// Create the pipeline if it doesn't exists, otherwise, keep is as is.
		if err := generateFileFromTemplate("docker-build.yaml", application, filepath.Join(target, "docker-build.yaml")); err != nil {
			return err
		}
	}
	for _, c := range application.Components {
		component := Component{
			Name:        c,
			Application: application.Name,
			Repository:  application.Repository,
			Branch:      application.Branch,
		}
		if err := generateFileFromTemplate("component-pull-request.yaml", component, filepath.Join(target, fmt.Sprintf("%s-pull-request.yaml", c))); err != nil {
			return err
		}
		if err := generateFileFromTemplate("component-push.yaml", component, filepath.Join(target, fmt.Sprintf("%s-push.yaml", c))); err != nil {
			return err
		}
	}
	return nil
}

func generateKonflux(application Application, target string) error {
	log.Printf("Generate konflux manifest in %s\n", target)
	if err := os.MkdirAll(filepath.Join(target, application.Branch), 0o755); err != nil {
		return err
	}
	if err := generateFileFromTemplate("application.yaml", application, filepath.Join(target, application.Branch, "application.yaml")); err != nil {
		return err
	}
	if err := generateFileFromTemplate("tests.yaml", application, filepath.Join(target, application.Branch, "tests.yaml")); err != nil {
		return err
	}
	for _, c := range application.Components {
		if err := generateFileFromTemplate("component.yaml", Component{
			Name:        c,
			Application: application.Name,
			Repository:  application.Repository,
			Branch:      application.Branch,
		}, filepath.Join(target, application.Branch, fmt.Sprintf("component-%s.yaml", c))); err != nil {
			return err
		}
	}
	return nil
}

func generateGitHub(application Application, target string) error {
	log.Printf("Generate github manifests in %s\n", target)
	if err := os.MkdirAll(filepath.Join(target, "workflows"), 0o755); err != nil {
		return err
	}
	filename := fmt.Sprintf("update-sources.%s.yaml", application.Branch)
	if err := generateFileFromTemplate("update-sources.yaml", application, filepath.Join(target, "workflows", filename)); err != nil {
		return err
	}
	return nil
}

func generateFileFromTemplate(templateFile string, o interface{}, filepath string) error {
	tmpl, err := template.New(templateFile).Funcs(template.FuncMap{
		"hyphenize": func(str string) string {
			return nameFieldInvalidCharPattern.ReplaceAllString(str, "-")
		},
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
