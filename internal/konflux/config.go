package konflux

type Config struct {
	Name      string
	Versions  map[string]Version
	Repos     []Repository
	Resources []string
}

type Application struct {
	Name    string
	Repos   []Repository
	Version *Version
	Config  Config
}

type Repository struct {
	Name        string
	Upstream    string
	Url         string
	Branches    []Branch
	Components  []Component
	Application Application
	Version     string
	Tekton      Tekton
	GitHub      GitHub
}
type Branch struct {
	Versions       []string
	UpstreamBranch string `json:"upstream" yaml:"upstream"`
	Name           string
	Patches        []Patch
	Platforms      []string
	Repository     *Repository
}

type Component struct {
	Name          string
	Nudges        []string
	Dockerfile    string
	ImagePrefix   string `json:"image-prefix" yaml:"image-prefix"`
	ImageSuffix   string `json:"image-suffix" yaml:"image-suffix"`
	PrefetchInput string `json:"prefetch-input" yaml:"prefetch-input"`
	Version       Version
	Branch        Branch
	Repository    Repository
	Application   Application
	Tekton        Tekton
	NoImagePrefix bool `json:"no-image-prefix" yaml:"no-image-prefix"`
}

type Tekton struct {
	WatchedSources string `json:"watched-sources" yaml:"watched-sources"`
	EventType      string `json:"event_type" yaml:"event_type"`
	NudgeFiles     string `json:"build-nudge-files" yaml:"build-nudge-files"`
}

type GitHub struct {
	UpdateSources string `json:"update-sources" yaml:"update-sources"`
}

type Patch struct {
	Name   string
	Script string
}
type Version struct {
	Version     string
	ImagePrefix string `json:"image-prefix" yaml:"image-prefix"`
	ImageSuffix string `json:"image-suffix" yaml:"image-suffix"`
	AutoRelease bool   `json:"auto-release" yaml:"auto-release"`
	Branch      *Branch
}
