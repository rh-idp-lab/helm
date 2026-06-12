# helm — Agent Guide

Helm charts for the IDP Lab platform services. Each chart is deployed as an independent ArgoCD Application on OpenShift.

## Structure

```
helm/
  <service>/          One chart per platform service
    Chart.yaml
    values.yaml
    templates/
    <subchart>/       Subcharts for multi-step deployments
```

## Conventions

### OLM operators

Install operators via a single `Subscription` in `openshift-operators` — no dedicated `Namespace` or `OperatorGroup` needed (OpenShift provides a global one).

```yaml
metadata:
  namespace: openshift-operators
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
```

Reference: `helm/devspaces/templates/devspaces-subscription.yaml`

### ArgoCD sync waves

Use `argocd.argoproj.io/sync-wave` annotations to control deployment order within a chart. Typical sequence for operator-based deployments:

| Wave | Content |
|------|---------|
| -1 | Secrets, ConfigMaps (prereqs) |
| 0 | OLM Subscription |
| 1 | CRD-dependent ConfigMaps |
| 2 | Custom Resource (e.g. `Backstage`, `CheCluster`) |
| 3+ | Post-install jobs (e.g. config-template) |

Always add `SkipDryRunOnMissingResource=true` on CRD-dependent resources (Custom Resources applied after an operator installs its CRDs).

### Helm templates with literal `{{ }}`

To write `{{inherit}}` or any literal `{{ }}` inside a ConfigMap `data` value, escape with:

```
{{ "{{" }}inherit{{ "}}" }}
```

Do NOT put `{{inherit}}` in YAML comments — Helm parses comments too.

### Dynamic plugins (RHDH 1.9, chart: `redhat-developer-hub`)

- Bundled plugins use `./dynamic-plugins/dist/<name>` paths.
- Community plugins migrated to ghcr.io use `oci://ghcr.io/redhat-developer/rhdh-plugin-export-overlays/<name>:<tag>`.
- Tag format (section 4.3 of RHDH 1.9 dynamic plugins reference): `bs_<backstage-version>__<plugin-version>`.
- RHDH 1.9 = Backstage `1.45.3`.
- `{{inherit}}` only works for plugins present in `dynamic-plugins.default.yaml` (Red Hat supported / Tech Preview). Use explicit tags for community plugins.
- Source of truth: https://docs.redhat.com/en/documentation/red_hat_developer_hub/1.9/html-single/dynamic_plugins_reference/index

### Empty values in values.yaml

Many charts have intentionally empty values (e.g. `oauthClientId: `, `password: `). These are provided at runtime by ArgoCD via secret overrides or environment-specific values. **Do not replace them with `required`** — the charts must lint cleanly with empty defaults, and real values are always injected at deployment time.

Use `| default ""` in templates (not `required`) when a nil-safe default is needed for linting.

### Pre-commit hook

`helm lint` runs automatically on `git commit` via pre-commit. Only the charts touched by staged files are linted (fast — sub-second for a single chart).

To install the hook after cloning:
```bash
brew install pre-commit   # or pip install pre-commit
pre-commit install
```

The hook configuration is in `.pre-commit-config.yaml`. The script is `scripts/helm-lint.sh`.

### GitLab authentication

Never use `rootPassword` for git push operations. The GitLab root PAT is in the `root-user-personal-token` Secret in the `gitlab` namespace.

### ArgoCD Application retry

For charts deploying OLM operators, add retry to the Application:

```yaml
syncPolicy:
  syncOptions:
    - SkipDryRunOnMissingResource=true
  retry:
    limit: 10
    backoff:
      duration: 30s
      factor: 2
      maxDuration: 5m
```

## Charts overview

| Chart | Deployment type | Notes |
|-------|----------------|-------|
| `redhat-developer-hub` | OLM operator (`fast-1.9`) | 4 subcharts with sync waves |
| `keycloak` | OLM operator | |
| `external-secrets` | OLM operator (Red Hat) | |
| `devspaces` | OLM operator | |
| `openshift-pipelines` | OLM operator | |
| `quay` | OLM operator | |
| `rhtas` | OLM operator | |
| `gitlab` | Helm (official chart) | |
| `hashicorp-vault-for-lab` | Official Helm chart | |
| `gitops` | ArgoCD CR | |
| `noobaa` | OLM operator | |
