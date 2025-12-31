package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
)

const (
	konfluxDir = ".konflux"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, os.Kill)
	defer cancel()

	versions := flag.String("versions", "", "comma-separated versions to apply (e.g., '1-22,0-2'). If not provided, applies all versions in .konflux/")
	dryRun := flag.Bool("dry-run", false, "print commands without executing")
	flag.Parse()

	if *versions != "" {
		// Apply specific versions
		for _, version := range strings.Split(*versions, ",") {
			version = strings.TrimSpace(version)
			if version == "" {
				continue
			}
			versionDir := filepath.Join(konfluxDir, version)
			if _, err := os.Stat(versionDir); os.IsNotExist(err) {
				log.Fatalf("Version directory %s does not exist", versionDir)
			}
			if err := apply(ctx, versionDir, *dryRun); err != nil {
				log.Fatalln(err)
			}
		}
	} else {
		// Apply all versions in .konflux/
		entries, err := os.ReadDir(konfluxDir)
		if err != nil {
			log.Fatalf("Failed to read %s directory: %v", konfluxDir, err)
		}

		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			versionDir := filepath.Join(konfluxDir, entry.Name())
			if err := apply(ctx, versionDir, *dryRun); err != nil {
				log.Fatalln(err)
			}
		}
	}

	log.Println("Done applying Konflux manifests")
}

func apply(ctx context.Context, dir string, dryRun bool) error {
	log.Printf("Applying manifests from %s\n", dir)

	args := []string{"apply", "-R", "-f", dir}
	if dryRun {
		args = []string{"apply", "--dry-run=client", "-R", "-f", dir}
	}

	cmd := exec.CommandContext(ctx, "kubectl", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	log.Printf("Running: %s\n", cmd.String())

	return cmd.Run()
}
