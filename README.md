# `openshift-pipelines` hack repository

Contains a bunch of hack used for `openshift-pipelines` repositories.

- Generate prow configuration (and sync in `openshift/release`)
  - For `task*` repositories.
- Generate github workflows "matrix" for `task*` repositories.

TODO for automation:
(waveywaves)
- version given as name for downstream components (console, manual-approval-gate, tekton-cache)
- for repos which have an upstream, the lastest patch release for a minor release can be picked up from the upstream repo itself.
- cache was introduced in 1.18 and pruner in 1.19