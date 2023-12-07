package prowgen

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	gyaml "github.com/ghodss/yaml"
	cioperatorapi "github.com/openshift/ci-tools/pkg/api"
	"gopkg.in/yaml.v2"
	prowv1 "k8s.io/test-infra/prow/apis/prowjobs/v1"
)

type Repository struct {
	Repo               string             `json:"repository" yaml:"repository"`
	OpenShift          OpenShift          `json:"openshift" yaml:"openshift"`
	OpenShiftPipelines OpenShiftPipelines `json:"openshift-pipelines" yaml:"openshift-pipelines"`
	E2E                E2E                `json:"e2e" yaml:"e2e"`
	GolangVersion      string             `json:"golang" yaml:"golang"`
}

type E2E struct {
	Workflow string `json:"workflow" yaml:"workflow"`
}

type OpenShift struct {
	Version string `json:"version" yaml:"version"`
}
type OpenShiftPipelines struct {
	Versions []string `json:"versions" yaml:"versions"`
}

type ReleaseBuildconfiguration struct {
	cioperatorapi.ReleaseBuildConfiguration

	Path string
}

func GenerateReleaseBuildConfigurationFromConfig(repo *Repository) (*ReleaseBuildconfiguration, error) {
	tests, err := generateTestFromConfig(repo)
	if err != nil {
		return nil, err
	}
	return &ReleaseBuildconfiguration{
		ReleaseBuildConfiguration: cioperatorapi.ReleaseBuildConfiguration{
			InputConfiguration: cioperatorapi.InputConfiguration{
				BaseImages: map[string]cioperatorapi.ImageStreamTagReference{
					fmt.Sprintf("openshift_release_golang-%s", repo.GolangVersion): {
						Name:      "release",
						Namespace: "openshift",
						Tag:       fmt.Sprintf("golang-%s", repo.GolangVersion),
					},
				},
				BuildRootImage: &cioperatorapi.BuildRootImageConfiguration{
					ImageStreamTagReference: &cioperatorapi.ImageStreamTagReference{
						Name:      "builder",
						Namespace: "ocp",
						Tag:       fmt.Sprintf("rhel-8-golang-%s-openshift-%s", repo.GolangVersion, repo.OpenShift.Version),
					},
				},
			},
			Images: []cioperatorapi.ProjectDirectoryImageBuildStepConfiguration{{
				ProjectDirectoryImageBuildInputs: cioperatorapi.ProjectDirectoryImageBuildInputs{
					Inputs: map[string]cioperatorapi.ImageBuildInputs{
						fmt.Sprintf("openshift_release_golang-%s", repo.GolangVersion): {
							As: []string{fmt.Sprintf("registry.ci.openshift.org/openshift/release:golang-%s", repo.GolangVersion)},
						},
					},
				},
				To: cioperatorapi.PipelineImageStreamTagReference("base-tests"),
			}},
			Resources: cioperatorapi.ResourceConfiguration{
				"*": cioperatorapi.ResourceRequirements{
					Limits: cioperatorapi.ResourceList{
						"cpu":    "100m",
						"memory": "200Mi",
					},
					Requests: cioperatorapi.ResourceList{
						"memory": "4Gi",
					},
				},
			},
			Tests: tests,
			Metadata: cioperatorapi.Metadata{
				Org:    "openshift-pipelines",
				Repo:   repo.Repo,
				Branch: "main",
			},
		},
	}, nil
}

func generateTestFromConfig(repo *Repository) ([]cioperatorapi.TestStepConfiguration, error) {
	tests := []cioperatorapi.TestStepConfiguration{}
	clusterClaim := getClusterClaim(repo.OpenShift.Version)
	switch repo.E2E.Workflow {
	case "tasks":
		for _, version := range repo.OpenShiftPipelines.Versions {
			version := version
			tests = append(tests, cioperatorapi.TestStepConfiguration{
				As:           fmt.Sprintf("osp-%s-ocp-%s-e2e", k8sNameString(version), k8sNameString(repo.OpenShift.Version)),
				ClusterClaim: clusterClaim,
				MultiStageTestConfiguration: &cioperatorapi.MultiStageTestConfiguration{
					AllowSkipOnSuccess:       pTrue(),
					AllowBestEffortPostSteps: pTrue(),
					Post:                     getTaskPostSteps(),
					Test: []cioperatorapi.TestStep{{
						LiteralTestStep: &cioperatorapi.LiteralTestStep{
							As:       "e2e",
							Cli:      "latest",
							Commands: fmt.Sprintf("make OSP_VERSION=%s test-e2e-openshift", version),
							From:     "base-tests",
							Resources: cioperatorapi.ResourceRequirements{
								Requests: cioperatorapi.ResourceList{
									"cpu": "100m",
								},
							},
						},
					}},
					Workflow: stringPtr("generic-claim"),
				},
			})
		}
	default:
		return tests, fmt.Errorf("unknown workflow %q", repo.E2E.Workflow)
	}
	return tests, nil
}

func getTaskPostSteps() []cioperatorapi.TestStep {
	return []cioperatorapi.TestStep{{
		LiteralTestStep: &cioperatorapi.LiteralTestStep{
			As:                "openshift-pipelines-must-gather",
			BestEffort:        pTrue(),
			OptionalOnSuccess: pFalse(),
			Cli:               "latest",
			Commands:          "oc adm must-gather --image=quay.io/openshift-pipeline/must-gather --dest-dir \"${ARTIFACT_DIR}/gather-openshift-pipelines\"",
			From:              "base-tests",
			Resources: cioperatorapi.ResourceRequirements{
				Requests: cioperatorapi.ResourceList{
					"cpu": "100m",
				},
			},
			Timeout: &prowv1.Duration{time.Duration(20) * time.Minute},
		},
	}, {
		LiteralTestStep: &cioperatorapi.LiteralTestStep{
			As:                "openshift-must-gather",
			BestEffort:        pTrue(),
			OptionalOnSuccess: pFalse(),
			Cli:               "latest",
			Commands:          "oc adm must-gather --dest-dir \"${ARTIFACT_DIR}/gather-openshift\"",
			From:              "base-tests",
			Resources: cioperatorapi.ResourceRequirements{
				Requests: cioperatorapi.ResourceList{
					"cpu": "100m",
				},
			},
			Timeout: &prowv1.Duration{time.Duration(20) * time.Minute},
		},
	}, {
		LiteralTestStep: &cioperatorapi.LiteralTestStep{
			As:                "openshift-gather-extra",
			BestEffort:        pTrue(),
			OptionalOnSuccess: pFalse(),
			Cli:               "latest",
			Commands:          "curl -skSL https://raw.githubusercontent.com/openshift/release/master/ci-operator/step-registry/gather/extra/gather-extra-commands.sh | /bin/bash -s",
			From:              "base-tests",
			GracePeriod:       &prowv1.Duration{time.Duration(1) * time.Minute},
			Resources: cioperatorapi.ResourceRequirements{
				Requests: cioperatorapi.ResourceList{
					"cpu":    "300m",
					"memory": "300Mi",
				},
			},
			Timeout: &prowv1.Duration{time.Duration(20) * time.Minute},
		},
	}}
}

func getClusterClaim(ocpVersion string) *cioperatorapi.ClusterClaim {
	return &cioperatorapi.ClusterClaim{
		Architecture: "amd64",
		As:           "latest",
		Cloud:        cioperatorapi.CloudAWS,
		Owner:        "openshift-ci",
		Product:      cioperatorapi.ReleaseProductOCP,
		Timeout:      &prowv1.Duration{time.Duration(60) * time.Minute},
		Version:      ocpVersion,
	}
}

func k8sNameString(s string) string {
	return strings.ReplaceAll(strings.ToLower(s), ".", "")
}

var (
	t = true
	f = false
)

func pTrue() *bool {
	return &t
}

func pFalse() *bool {
	return &f
}

func stringPtr(s string) *string {
	return &s
}

func SaveReleaseBuildConfiguration(outConfig *string, cfg ReleaseBuildconfiguration) error {
	dir := filepath.Join(*outConfig, filepath.Dir(cfg.Path))

	if err := os.MkdirAll(dir, os.ModePerm); err != nil {
		return err
	}
	// Going directly from struct to YAML produces unexpected configs (due to missing YAML tags),
	// so we produce JSON and then convert it to YAML.
	out, err := json.Marshal(cfg.ReleaseBuildConfiguration)
	if err != nil {
		return err
	}
	out, err = gyaml.JSONToYAML(out)
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*outConfig, cfg.Path), out, os.ModePerm); err != nil {
		return err
	}
	return nil
}

func Main() {
	inputConfig := flag.String("config", filepath.Join("config", "repositories.yaml"), "Specify repositories config")
	outConfig := flag.String("output", filepath.Join("openshift", "release", "ci-operator", "config"), "Specify repositories config")
	remote := flag.String("remote", "", "openshift/release remote fork (example: git@github.com:pierDipi/release.git)")
	branch := flag.String("branch", "sync-serverless-ci", "Branch for remote fork")
	flag.Parse()

	log.Println(*inputConfig, *outConfig, *remote, *branch)

	in, err := os.ReadFile(*inputConfig)
	if err != nil {
		log.Fatalln(err)
	}
	repo := &Repository{}
	if err := yaml.UnmarshalStrict(in, repo); err != nil {
		log.Fatalln("Unmarshal input config", err)
	}
	cfg, err := GenerateReleaseBuildConfigurationFromConfig(repo)
	if err != nil {
		log.Fatalln(err)
	}
	// FIXME: put the real file
	cfg.Path = filepath.Join("openshift-pipelines", repo.Repo, "foo.yaml")
	if err := SaveReleaseBuildConfiguration(outConfig, *cfg); err != nil {
		log.Fatalln(err)
	}
	log.Printf("config: %+v\n", cfg)
}
