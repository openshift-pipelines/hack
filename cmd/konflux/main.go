package main

import (
	"embed"
	"flag"
	"fmt"
	"log"
	"os"
	"path"
	"path/filepath"
	"text/template"

	"gopkg.in/yaml.v2"
)

//go:embed templates/konflux/*.yaml templates/github/*/*.yaml
var templateFS embed.FS

type Application struct {
	Name       string
	Repository string
	Components []string
}

type Component struct {
	Name        string
	Application string
	Repository  string
}

type Config struct {
	Repository string
	Components []string
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
		Name:       c.Repository,
		Repository: path.Join("openshift-pipelines", c.Repository),
		Components: c.Components,
	}

	if err := generateKonflux(app, filepath.Join(*target, ".konflux")); err != nil {
		log.Fatalln(err)
	}
	if err := generateGitHub(app, filepath.Join(*target, ".github")); err != nil {
		log.Fatalln(err)
	}
}

func generateKonflux(application Application, target string) error {
	log.Printf("Generate konflux manifest in %s\n", target)
	if err := os.MkdirAll(target, 0o755); err != nil {
		return err
	}
	if err := generateFileFromTemplate("application.yaml", application, filepath.Join(target, "application.yaml")); err != nil {
		return err
	}
	if err := generateFileFromTemplate("tests.yaml", application, filepath.Join(target, "tests.yaml")); err != nil {
		return err
	}
	for _, c := range application.Components {
		if err := generateFileFromTemplate("component.yaml", Component{
			Name:        c,
			Application: application.Name,
			Repository:  application.Repository,
		}, filepath.Join(target, fmt.Sprintf("component-%s.yaml", c))); err != nil {
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
	if err := generateFileFromTemplate("update-sources.yaml", application, filepath.Join(target, "workflows", "update-sources.yaml")); err != nil {
		return err
	}
	if err := generateFileFromTemplate("update-sources-branches.yaml", application, filepath.Join(target, "workflows", "update-sources-branches.yaml")); err != nil {
		return err
	}
	return nil
}

func generateFileFromTemplate(templateFile string, o interface{}, filepath string) error {
	tmpl, err := template.New(templateFile).ParseFS(templateFS, "templates/*/*.yaml", "templates/*/*/*.yaml")
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
