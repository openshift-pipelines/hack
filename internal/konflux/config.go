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
	ImagePrefix   string `json:"image-prefix" yaml:"image-prefix"`
	ImageSuffix   string `json:"image-suffix" yaml:"image-suffix"`
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
	NudgeFiles     string `json:"build-nudge-files" yaml:"build-nudge-files"`
}

type Branch struct {
	Versions       []Version
	UpstreamBranch string `json:"upstream" yaml:"upstream"`
	Name           string
	Patches        []Patch
	Platforms      []string
}

type Patch struct {
	Name   string
	Script string
}

type Version struct {
	Version string
	Release string
}
