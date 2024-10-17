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
	Version        string
	GitHub         GitHub
	Tekton         Tekton
}

type Component struct {
	Name        string
	Application string
	Repository  string
	Branch      string
	Version     string
	Tekton      Tekton
}

type Config struct {
	Repository string
	Upstream   string
	GitHub     GitHub
	Tekton     Tekton
	Components []string
	Branches   []Branch
}

type GitHub struct {
	UpdateSources string `json:"update-sources" yaml:"update-sources"`
}

type Tekton struct {
	WatchedSources string `json:"watched-sources" yaml:"watched-sources"`
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
		Version:        "main",
		GitHub:         c.GitHub,
		Tekton:         c.Tekton,
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
			Version:        branch.Version,
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

	// set defaults
	if application.Tekton.WatchedSources == "" {
		application.Tekton = Tekton{WatchedSources: `"upstream/***".pathChanged() || "openshift/patches/***".pathChanged() || "openshift/rpms/***".pathChanged()`}
	}

	for _, c := range application.Components {
		component := Component{
			Name:        c,
			Application: application.Name,
			Repository:  application.Repository,
			Branch:      application.Branch,
			Version:     application.Version,
			Tekton:      application.Tekton,
		}
		if err := generateFileFromTemplate("component-pull-request.yaml", component, filepath.Join(target, fmt.Sprintf("%s-%s-%s-pull-request.yaml", hyphenize(basename(application.Repository)), hyphenize(application.Version), c))); err != nil {
			return err
		}
		if err := generateFileFromTemplate("component-push.yaml", component, filepath.Join(target, fmt.Sprintf("%s-%s-%s-push.yaml", hyphenize(basename(application.Repository)), hyphenize(application.Version), c))); err != nil {
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
			Version:     application.Version,
		}, filepath.Join(target, application.Branch, fmt.Sprintf("component-%s.yaml", c))); err != nil {
			return err
		}
		if err := generateFileFromTemplate("image.yaml", Component{
			Name:        c,
			Application: application.Name,
			Repository:  application.Repository,
			Branch:      application.Branch,
			Version:     application.Version,
		}, filepath.Join(target, application.Branch, fmt.Sprintf("image-%s.yaml", c))); err != nil {
			return err
		}
	}
	return nil
}

func generateGitHub(application Application, target string) error {
	if application.Upstream == "" {
		// Only generate the github workflows if there is an upstream
		return nil
	}
	log.Printf("Generate github manifests in %s\n", target)
	if err := os.MkdirAll(filepath.Join(target, "workflows"), 0o755); err != nil {
		return err
	}
	filename := fmt.Sprintf("update-sources.%s.yaml", application.Branch)
	if err := generateFileFromTemplate("update-sources.yaml", application, filepath.Join(target, "workflows", filename)); err != nil {
		return err
	}
	amfilename := fmt.Sprintf("auto-merge.%s.yaml", application.Branch)
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
