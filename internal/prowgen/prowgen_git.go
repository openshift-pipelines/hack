package prowgen

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
)

func repositoryDirectory(r string) string {
	return filepath.Join("repos", r)
}

func GitCheckout(ctx context.Context, r string, branch string) error {
	_, err := run(ctx, repositoryDirectory(r), "git", "checkout", branch)
	return err
}

func GitMirror(ctx context.Context, r string) error {
	return gitClone(ctx, r, true)
}

func GitClone(ctx context.Context, r string) error {
	return gitClone(ctx, r, false)
}

func gitClone(ctx context.Context, r string, mirror bool) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	if _, err := os.Stat(repositoryDirectory(r)); !errors.Is(err, os.ErrNotExist) {
		log.Println("Repository", repositoryDirectory(r), "already cloned")
		return nil
	}

	if err := os.RemoveAll(repositoryDirectory(r)); err != nil {
		return fmt.Errorf("[%s] failed to delete directory: %w", repositoryDirectory(r), err)
	}

	if err := os.MkdirAll(filepath.Dir(repositoryDirectory(r)), os.ModePerm); err != nil {
		return fmt.Errorf("[%s] failed to create directory: %w", repositoryDirectory(r), err)
	}

	remoteRepo := fmt.Sprintf("https://github.com/%s.git", r)
	if mirror {
		log.Println("Mirroring repository", repositoryDirectory(r))
		if _, err := runNoRepo(ctx, "git", "clone", "--mirror", remoteRepo, filepath.Join(repositoryDirectory(r), ".git")); err != nil {
			return fmt.Errorf("[%s] failed to clone repository: %w", repositoryDirectory(r), err)
		}
		if _, err := run(ctx, repositoryDirectory(r), "git", "config", "--bool", "core.bare", "false"); err != nil {
			return fmt.Errorf("[%s] failed to set config for repository: %w", repositoryDirectory(r), err)
		}
	} else {
		log.Println("Cloning repository", repositoryDirectory(r))
		if _, err := runNoRepo(ctx, "git", "clone", remoteRepo, repositoryDirectory(r)); err != nil {
			return fmt.Errorf("[%s] failed to clone repository: %w", repositoryDirectory(r), err)
		}
	}

	return nil
}

func GitMerge(ctx context.Context, r string, sha string) error {
	_, err := run(ctx, repositoryDirectory(r), "git", "merge", sha, "--no-ff", "-m", "Merge "+sha)
	return err
}

func GitFetch(ctx context.Context, r string, sha string) error {
	remoteRepo := fmt.Sprintf("https://github.com/%s.git", r)
	_, err := run(ctx, repositoryDirectory(r), "git", "fetch", remoteRepo, sha)
	return err
}

func GitDiffNameOnly(ctx context.Context, r string, sha string) ([]string, error) {
	out, err := run(ctx, r, "git", "diff", "--name-only", sha)
	if err != nil {
		return nil, err
	}
	return strings.Split(strings.TrimSpace(string(out)), "\n"), nil
}
