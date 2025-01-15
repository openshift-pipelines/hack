package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
)

func run(ctx context.Context, r string, name string, args ...string) ([]byte, error) {
	var buf bytes.Buffer

	select {
	case <-ctx.Done():
		return buf.Bytes(), ctx.Err()
	default:
	}

	log.Println("Running", name, args, "in", r)
	cmd := exec.Command(name, args...)

	cmd.Dir = r
	// cmd.Stdout = io.MultiWriter(os.Stdout, &buf)
	cmd.Stdout = &buf
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return buf.Bytes(), fmt.Errorf("[%s] failed to run %s %v: %w", r, name, args, err)
	}
	return buf.Bytes(), nil
}
