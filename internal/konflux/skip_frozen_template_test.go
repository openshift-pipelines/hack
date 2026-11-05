package konflux

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestUpdateSourcesAllIncludesFrozenFilter(t *testing.T) {
	dir := t.TempDir()
	app := Application{Name: "test", Release: &Release{Version: "1.24"}}
	data := struct {
		Repository
		FrozenBranches []string
	}{
		Repository:     Repository{Application: app},
		FrozenBranches: []string{"release-v1.24.x"},
	}
	out := filepath.Join(dir, "update-sources.yaml")
	if err := generateFileFromTemplate("update-sources-all.yaml", data, out, app); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	s := string(got)
	if !strings.Contains(s, "Skipping frozen branches") {
		t.Fatalf("expected frozen filter in generated workflow, got:\n%s", s)
	}
	if strings.Contains(s, `echo "$branches"          frozen=`) {
		t.Fatalf("left-trim glued shell lines together:\n%s", s)
	}
}
