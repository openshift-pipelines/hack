package konflux

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
	Patches        []Patch
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
	Patches    []Patch
}

type GitHub struct {
	UpdateSources string `json:"update-sources" yaml:"update-sources"`
}

type Tekton struct {
	WatchedSources string `json:"watched-sources" yaml:"watched-sources"`
	EventType      string `json:"event_type" yaml:"event_type"`
}

type Branch struct {
	Version  string
	Upstream string
	Branch   string
	Patches  []Patch
}

type Patch struct {
	Name   string
	Script string
}
