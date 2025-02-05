package konflux

type Application struct {
	Name           string
	Repository     string
	Upstream       string
	Branch         string
	UpstreamBranch string
	Components     []Component
	Version        string
	GitHub         GitHub
	Tekton         Tekton
	Patches        []Patch
	Platforms      []string
	ReleasePlan    bool
}

type Component struct {
	Name          string
	Application   string
	Repository    string
	Branch        string
	Version       string
	Tekton        Tekton
	Platforms     []string
	Nudges        []string
	Dockerfile    string
	PrefetchInput string `json:"prefetch-input" yaml:"prefetch-input"`
}

type Config struct {
	Repository string
	Upstream   string
	GitHub     GitHub
	Tekton     Tekton
	Components []Component
	Branches   []Branch
	Patches    []Patch
	Platforms  []string
}

type GitHub struct {
	UpdateSources string `json:"update-sources" yaml:"update-sources"`
}

type Tekton struct {
	WatchedSources string `json:"watched-sources" yaml:"watched-sources"`
	EventType      string `json:"event_type" yaml:"event_type"`
}

type Branch struct {
	Version   string
	Upstream  string
	Branch    string
	Patches   []Patch
	Platforms []string
	Release   string
}

type Patch struct {
	Name   string
	Script string
}
