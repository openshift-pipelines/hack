package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"

	k "github.com/openshift-pipelines-konflux/hack/internal/konflux"
	"gopkg.in/yaml.v2"
)

const (
	konfluxDir = ".konflux"
	osp        = "https://github.com/openshift-pipelines/"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, os.Kill)
	defer cancel()

	config := flag.String("config", filepath.Join("config", "konflux", "repository.yaml"), "specify the repository configuration")
	flag.Parse()

	in, err := os.ReadFile(*config)
	if err != nil {
		log.Fatalln(err)
	}
	c := &k.Config{}
	if err := yaml.UnmarshalStrict(in, c); err != nil {
		log.Fatalln("Unmarshal config", err)
	}

	for _, b := range c.Branches {
		var versions []string
		if len(b.Versions) == 0 {
			versions = []string{b.Name}
		} else {
			for _, v := range b.Versions {
				versions = append(versions, v.Version)
			}
		}

		// Create temporary folder
		dir, err := os.MkdirTemp("", "konflux-apply")
		if err != nil {
			log.Fatalln(err)
		}

		// Clone repository
		if err := gitClone(ctx, dir, c.Repository, b.Name); err != nil {
			log.Fatalln(err)
		}
		//Kubectl apply
		if err := apply(ctx, dir, versions); err != nil {
			log.Fatalln(err)
		}
	}
}

func apply(ctx context.Context, dir string, versions []string) error {
	for _, version := range versions {
		log.Printf("Apply %s on the cluster\n", version)
		cmd := exec.CommandContext(ctx, "kubectl", "apply", "-R", "-f", filepath.Join(konfluxDir, version))
		cmd.Dir = dir
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr

		log.Printf("Final CMD : %s\n", cmd.String())

		if err := cmd.Run(); err != nil {
			return err
		}
	}
	return nil
}

func gitClone(ctx context.Context, dir, repository string, branch string) error {
	log.Printf("Cloning %s in %s\n", osp+repository, dir)
	cmd := exec.CommandContext(ctx, "git", "clone", "-b", branch, osp+repository, ".")
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	return cmd.Run()
}
