# actions

Reusable GitHub Actions and pipelines for services that build a Docker image and deploy a Kubernetes manifest. Service repositories stay thin: they call one reusable workflow and inherit the whole pipeline.

## Layout

| Path | Kind | Purpose |
| --- | --- | --- |
| `go-build/` | composite action | Go toolchain setup + gofmt gate + vet + build + test |
| `validate-manifest/` | composite action | dry-run apply of a manifest against a cluster |
| `deploy-manifest/` | composite action | build + push image, render tag into manifest, apply, wait for rollout |
| `.github/workflows/ci_pipeline_go.yaml` | reusable workflow | CI for a Go service |
| `.github/workflows/cd_pipeline_go.yaml` | reusable workflow | CD for a Go service (dev/prod, release gate, environments) |
| `.github/workflows/manual_create_release.yaml` | workflow | tags a release of this repo from the Actions tab |

## Using from a service repository

CI on every push and pull request:

```yaml
name: ci
on:
  push:
    branches: [main]
  pull_request:
jobs:
  ci:
    uses: 5thtable/actions/.github/workflows/ci_pipeline_go.yaml@v1
    with:
      go-version: "1.25"
```

CD to development on every push to main:

```yaml
name: cd
on:
  push:
    branches: [main]
jobs:
  cd:
    uses: 5thtable/actions/.github/workflows/cd_pipeline_go.yaml@v1
    with:
      image-registry: ghcr.io/my-org
      target-environment: development
      manifest-file: infra/service.yaml
      rollout-deployment: my-service
      rollout-namespace: my-namespace
    secrets:
      kubeconfig-dev: ${{ secrets.KUBECONFIG_DEV }}
      registry-username: ${{ github.actor }}
      registry-password: ${{ secrets.GITHUB_TOKEN }}
```

Production is the same call with `target-environment: production` and `kubeconfig-prod`, typically behind a `workflow_dispatch` trigger and a protected `production` environment.

The manifest must contain the literal placeholder `<container-image>` where the image reference belongs; `deploy-manifest` refuses to apply a manifest that lacks it.

## Releasing this repository

Actions are consumed by tag (`@v1`). To move the tag, run the **Manual tag release** workflow from the Actions tab on the branch to release. Consumers pick up the new behavior on their next run; breaking changes go to a new major tag instead of moving an old one.

## Design rules

- Every dynamic value crosses into shell through `env:`, never through expression interpolation inside `run:` scripts, so branch names, repository names, and inputs cannot inject shell.
- Kubeconfigs are written to `mktemp` files under `RUNNER_TEMP` and exported via `KUBECONFIG`, then removed in an `always()` step: concurrent jobs on a shared runner cannot clobber each other, and nothing persists in the runner home.
- `docker build --pull` keeps base images fresh on long-lived runners.
- Image tags are `[<environment>.]<short-sha>.<run-number>`: unique per build, sortable, and enough to trace any running pod back to its commit and workflow run.
- Deploy pipelines never cancel in-flight runs (`cancel-in-progress: false`); CI does.
- Deploys are refused while a `STOP_RELEASE` file exists at the service repo root, so any committer can freeze releases with one commit and unfreeze with its revert.
- Third-party actions are referenced only from trusted publishers at major tags; anything else gets pinned to a commit SHA.
- Reusable workflows reference actions in this repository by absolute `owner/repo/path@tag`, because relative `./` paths inside a reusable workflow resolve against the calling repository's checkout.
