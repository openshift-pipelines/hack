# `openshift-pipelines` hack repository

Contains a bunch of hack used for `openshift-pipelines` repositories.

- Generate prow configuration (and sync in `openshift/release`)
  - For `task*` repositories.
- Generate github workflows "matrix" for `task*` repositories.

TODO:
Table which contains
- which components were introduced newly in which pipelines version. This will help us to filter out which componets which don't need to be updated for a version. This information can be taken from the http://dashboard.apps.cicd.ospqa.com/releases/
- version given as name for downstream components (console, manual-approval-gate, tekton-cache)
- for repos which have an upstream, the lastest patch release for a minor release can be picked up from the upstream repo itself.
- from the table pick up map upstream release to downstream release if upstream field is given. http://dashboard.apps.cicd.ospqa.com/releases/
- cache was introduced in 1.18 and pruner in 1.19