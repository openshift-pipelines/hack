# `openshift-pipelines` hack repository

Contains a bunch of hack used for `openshift-pipelines` repositories.

- Generate prow configuration (and sync in `openshift/release`)
  - For `task*` repositories.
- Generate github workflows "matrix" for `task*` repositories.
- Generate and store the configuration for Konflux resources and automation (build PipelineRuns, ReleasePlans, etc)

---
## Adding New Release
Now release can be added just a click of button.
- From Action Menu on github select action "Release Action - New Release"
- Run Workflow with the following inputs:
  - Select `main` branch
  - Version: Provide the version you want to add e.g `1.23` (will create the tag `1.23.0-RC-1`)
- This workflow will add new PR to hack repo with updated version configuration for the Release Candidate.
- Verify the PR and merge
- Repeat the above for subsequent Release Candidate builds
- When ready to create the final pre-stage release, from the Action Menu on Github run select the action "Release Action - Finalize RC"
- Run the workflow with the following inputs:
  - Select `main` branch
  - Version: Provide the version you want to finalize (e.g. `1.23`)
- This workflow will add new PR to the hack repo that removes the RC suffix from the release's version.
- Verify the PR and merge

After the initial PR is merged then new workflow will be triggered which will generate release configuration in all the Repos.
The initial release will be configured as a Release Candidate with a version like 1.23.0-RC-1.

---
## Adding New Patch
When planning a new patch release for a specific  minor verson then it is essential to tag the images appropriately.

- From Action Menu on github select action "Automated Release Actions"
- Run Workflow
- Select appropriate Branch
- Action : new-patch
- Version: Provide the version you want to add e.g 1.23
- Run Workflow
- This workflow will add new PR to hack repo with updated version configuration.
- Verify the PR and merge

After PR is merged then new workflow will be triggered which will generate release configuration in all the Repos.

---
## Refreshing Upstream Branches
Upstream branches for next release are syned daily. if there is any update in upstream branch name the  you will see a 
    PR in hack repo with updated upstream branches in next.yaml.

You can also trigger this workflow manually for next branch or any other branch

It is recommended not to update the upstream branches for released versions. however you may need to update the upstream 
versions for unreleased versions which you can do by this workflow.

- From Action Menu on github select action "Automated Release Actions"
- Run Workflow
- Select appropriate Branch
- Action : update-upstream-versions
- Version: Provide the downstream minor version you want to add or update. e.g "1.23" or "next"
- Run Workflow
- This workflow will add new PR to hack repo with updated version configuration.
- Verify the PR and merge
After PR is merged then new workflow will be triggered which will generate release configuration in all the Repos.

---
 

TODO for automation:
(waveywaves)
- version given as name for downstream components (console, manual-approval-gate, tekton-cache)
- for repos which have an upstream, the lastest patch release for a minor release can be picked up from the upstream repo itself.
- cache was introduced in 1.18 and pruner in 1.19
