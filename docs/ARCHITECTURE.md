# OpenClaw k3s/Argo/Helm Architecture

This repo is the production GitOps control plane for your OpenClaw-on-k3s deployment.

## Goals

- Run one reliable OpenClaw Gateway on local k3s.
- Manage deployment, config baseline, and workspace baseline through GitOps.
- Keep mutable runtime state persistent across pod restarts.
- Make cutover from the existing systemd Gateway reversible.

## Non-goals

- Active-active OpenClaw gateways.
- Public internet exposure for the OpenClaw Gateway. Grafana can be exposed separately through the optional, password-protected ngrok bridge documented in `MONITORING.md`.
- Terraform-managed infrastructure.
- Argo pruning of all workspace files.

## Components

```text
Git repo: openclaw-k3s (desired slug; current remote may still be openclaw-k3s until coordinated rename)
  ├─ chart/openclaw/              Helm chart
  ├─ chart/openclaw/workspace/    GitOps workspace overlay
  ├─ argocd/application.yaml      Argo CD Application
  └─ docs/                        Architecture and runbooks

k3s cluster on openclaw host
  ├─ namespace/argocd             Argo CD controller
  └─ namespace/openclaw
      ├─ Deployment/openclaw      single Gateway pod
      ├─ Service/openclaw         ClusterIP :18789
      ├─ PVC/openclaw-state       persistent /home/node/.openclaw
      ├─ optional Prometheus/Grafana monitoring resources
      ├─ Secret/openclaw-secrets  model/gateway secrets, manual for now
      └─ Secret/workspace-git-credentials optional Git credentials
```

## Gateway deployment model

OpenClaw runs as a single active Kubernetes Deployment with `replicas: 1` and `strategy: Recreate`.

That is intentional. OpenClaw owns channel connections, cron/background work, credentials, local session state, and mutable workspace state. Running multiple active replicas against the same state risks duplicate message handling and state races.

Current reliability comes from:

- k3s/systemd supervising the node and kubelet
- Kubernetes restarting the pod when it exits
- `/healthz` liveness probe
- `/readyz` readiness probe
- Argo CD reconciling declared manifests
- PVC-backed state surviving pod replacement
- off-host backups and restore drills once Kopia credentials are in place
- HA k3s/replicated storage as the production target once hardware is available

## Storage model

The chart mounts `openclaw-state` at:

```text
/home/node/.openclaw
```

This PVC contains runtime state, including:

- `workspace/`
- agent/session files
- logs/stability bundles
- browser/canvas state
- any runtime-created OpenClaw files

The backing storage is k3s `local-path` storage on the current host. Treat the PVC as the source of truth rather than editing local-path directories directly.

## Config model

The Helm chart renders baseline `openclaw.json` from `values.yaml` into a ConfigMap.

At pod startup:

1. `render-config` initContainer copies ConfigMap config into writable `emptyDir` at `/config-work/openclaw.json`.
2. Ownership is set to UID/GID `1000:1000` for the OpenClaw container.
3. The main container starts with `OPENCLAW_CONFIG_PATH=/config-work/openclaw.json`.

This avoids mounting the ConfigMap directly as the runtime config file, because OpenClaw may write last-good backups, seed default values, or apply safe config mutations next to the config file.

Current tradeoff: runtime config mutations are not persisted back to Git. Desired config changes should be made in Git and rolled through Argo.

## GitOps workspace model

The chart manages a workspace overlay from:

```text
chart/openclaw/workspace/**
```

A `workspace-sync` initContainer runs before the Gateway starts. It:

1. Writes the GitOps workspace overlay into `/home/node/.openclaw/workspace`.
2. Reconciles declared projects from `workspace.projects[]` in `values.yaml`.
3. Chowns the workspace to UID/GID `1000:1000`.

Example declared project:

```yaml
workspace:
  enabled: true
  projects:
    - name: openclaw-k3s
      enabled: true
      repo: https://github.com/YOUR_GITHUB_ORG/openclaw-k3s.git
      branch: main
      path: projects/openclaw-k3s
```

For existing project directories, the sync step fetches the target branch and hard-resets to `origin/<branch>`. This is good for reproducible managed repos, but dangerous for active WIP. Do not add development repos here unless hard-reset behavior is acceptable.

## Workspace ownership policy

Recommended split:

### GitOps-managed

- baseline `AGENTS.md`, `README.md`, onboarding docs
- non-secret scripts that should exist in every Gateway pod
- custom skills we want reproducible
- declared managed project clones

### PVC/runtime-owned

- secrets and credentials
- logs and stability bundles
- active sessions
- transient tool outputs
- scratch projects or WIP repos
- bulky generated artifacts

## Secrets model

Current deployment still uses manual Kubernetes Secrets while SOPS is being wired:

- `openclaw-secrets`
  - `OPENCLAW_GATEWAY_TOKEN`
  - `OPENAI_API_KEY`
- `workspace-git-credentials`
  - `GIT_USERNAME`
  - `GIT_PASSWORD`
- `openclaw-grafana-admin` (when monitoring is enabled)
  - `admin-user`
  - `admin-password`
- `openclaw-grafana-ngrok` (only when ngrok Grafana access is enabled)
  - `NGROK_AUTHTOKEN`

This is intentionally not committed to Git.

Target state:

- SOPS + age encrypted Kubernetes Secret manifests committed to Git
- Argo CD config-management-plugin decrypts manifests at sync time
- Manual Kubernetes Secrets are retired one at a time, lowest blast radius first

## Current validation commands

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm lint chart/openclaw
helm template openclaw chart/openclaw --namespace openclaw > /tmp/openclaw-rendered.yaml
kubectl apply --dry-run=server -f /tmp/openclaw-rendered.yaml
kubectl -n argocd get application openclaw -o wide
kubectl -n openclaw get pods,svc,pvc
```

Health checks:

```bash
POD=$(kubectl -n openclaw get pod -l app.kubernetes.io/name=openclaw -o jsonpath='{.items[0].metadata.name}')
IP=$(kubectl -n openclaw get pod "$POD" -o jsonpath='{.status.podIP}')
curl -fsS "http://$IP:18789/healthz"
curl -fsS "http://$IP:18789/readyz"
```

## Image and tools baseline

As of 2026-05-13 the chart uses a **baked image** built from
`chart/openclaw/image/Dockerfile` (`scripts/build-image.sh` until a
Forgejo Actions runner exists). The image bundles runtime CLIs
(`kubectl`/`helm`/`argocd`/`jq`/`ssh`/`gogcli`/`todoist`) under
`/opt/openclaw-tools/` and preinstalls the `@openclaw/discord` +
`@openclaw/brave-plugin` packages at `/opt/openclaw-baked-state/`. The
chart's `image.bakedTools` toggle gates between this path (default) and
the legacy install-at-pod-start path documented in
[RUNTIME-TOOLS.md](./RUNTIME-TOOLS.md) and [GOGCLI-GITOPS.md](./GOGCLI-GITOPS.md).

## Known sharp edges

- Workspace project reconciliation hard-resets declared repos. Don't
  add WIP repos to `workspace.projects[]`.
- PVC currently uses k3s `local-path`; this is node-local, not HA. Host disk
  loss requires restore from backups until the HA/replicated-storage migration
  is complete. See [BACKUP-STRATEGY.md](./BACKUP-STRATEGY.md) and
  [HA-K3S-MIGRATION.md](./HA-K3S-MIGRATION.md).
- ConfigMap-derived runtime config can be mutated in-memory/on-emptyDir
  but not persisted back to Git. The PVC may also accumulate a stale
  `openclaw.json` — init containers that run openclaw subcommands must
  set `OPENCLAW_CONFIG_PATH=/config-work/openclaw.json` to avoid the
  fallback PVC copy.
- Forgejo Actions runner is currently on the k3s host as a temporary bridge.
  Move it to a dedicated CI host/VM before treating CI as production-isolated.
