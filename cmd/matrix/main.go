package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	args := os.Args[1:]
	projects := []string{}
	for _, a := range args {
		projects = append(projects, strings.TrimSuffix(filepath.Base(a), filepath.Ext(a)))
	}
	if err := json.NewEncoder(os.Stdout).Encode(projects); err != nil {
		panic(err)
	}
}
