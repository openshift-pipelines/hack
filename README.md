# `openshift-pipelines` hack repository

Contains a bunch of hack used for `openshift-pipelines` repositories.

- Generate prow configuration (and sync in `openshift/release`)
  - For `task*` repositories.
- Generate github workflows "matrix" for `task*` repositories.
---
## Adding New Release
Now release can be added just a click of button. 
- From Action Menu on github select action "Automated Release Actions"
- Run Workflow
- Select appropriate Branch
- Action : new-release
- Version: Provide the version you want to add e.g 1.23
- Run Workflow
- This workflow will add new PR to hack repo with updated version configuration.
- Verify the PR and merge

After PR is merged then new workflow will be triggered which will generate release configuration in all the Repos.

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
## Release Candidate (RC) Builds
RC builds follow the format `x.y.z-RC-α` where α starts at 1 and increments.

### RC Workflow
1. **Start RC**: Use `new-rc` action to create first RC build (e.g., `1.24.0-RC-1`)
2. **Increment RC**: Continue using `new-rc` to increment the RC number
3. **Auto-finalize**: After RC-2, `new-rc` automatically switches to full build
4. **Manual finalize**: Use `finalize-rc` to manually drop RC suffix when ready

### RC Options in GitHub Actions
- From Action Menu on github select action "Automated Release Actions"
- Run Workflow
- Select appropriate Branch
- Action : `new-rc` or `finalize-rc`
- Version: Provide the downstream minor version e.g "1.24"
- Run Workflow

### RC Configuration (in release yaml)
```yaml
version: 1.24
patch-version: 1.24.0-RC-1
is-rc: true
rc-number: 1
```

### Important Notes
- **During RC mode**: Upstream component versions automatically update when higher versions are released upstream
- **After x.y.0 release**: Minor versions of upstream components do NOT auto-update

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
