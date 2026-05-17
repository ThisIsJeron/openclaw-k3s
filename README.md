# OpenClaw k3s GitOps template

A homelab-friendly Kubernetes/GitOps deployment template for running a single OpenClaw Gateway on k3s with Helm, Argo CD, persistent state, monitoring, backup hooks, and safe rollback patterns.

This repository is a sanitized public template extracted from a real private deployment. It intentionally ships with safe defaults: no chat channels enabled, no public tunnels enabled, no encrypted live secrets, and no private registry assumptions.

## What this gives you

- Helm chart for OpenClaw Gateway
- Argo CD Application manifests
- PVC-backed `/home/node/.openclaw` runtime state
- optional kube-prometheus-stack monitoring
- optional Alertmanager Discord relay
- optional Kopia backup CronJob
- GitOps guard/rollback helper
- CI preflight for Helm rendering

## Quick start

1. Copy `examples/values.minimal.yaml` and adjust image/secrets for your environment.
2. Create required Kubernetes Secrets out-of-band or with SOPS.
3. Render locally:

```bash
helm dependency build chart/openclaw
helm lint chart/openclaw
helm template openclaw chart/openclaw --namespace openclaw -f examples/values.minimal.yaml
```

4. Update `argocd/apps/openclaw.yaml` to point at your Git repo.
5. Let Argo CD sync the app.

## Important safety notes

- Run only one active Gateway replica unless OpenClaw explicitly supports active-active operation for your use case.
- Do not commit live secrets. Use Kubernetes Secrets, SOPS, External Secrets, or your preferred secret manager.
- Treat the PVC as important state. Configure off-host backups before relying on this as production infrastructure.

## Docs

- [Architecture](docs/ARCHITECTURE.md)
- [Monitoring](docs/MONITORING.md)
- [Backup strategy](docs/BACKUP-STRATEGY.md)
- [Restore drill](docs/RESTORE-DRILL.md)
- [Secrets with SOPS](docs/SECRETS-SOPS.md)
- [GitOps rollback](docs/GITOPS-ROLLBACK.md)
- [Runtime tools](docs/RUNTIME-TOOLS.md)
- [Reliability plan](docs/RELIABILITY-PLAN.md)
