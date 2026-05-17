# OpenClaw k3s GitOps template

A homelab-friendly Kubernetes/GitOps deployment template for running a single OpenClaw Gateway on k3s with Helm, Argo CD, persistent state, monitoring, backup hooks, and safe rollback patterns.

This repository is a sanitized public template extracted from a real private deployment. It intentionally ships with safe defaults: no chat channels enabled, no public tunnels enabled, no encrypted live secrets, and no private registry assumptions.

## Why use this instead of the default setup?

The official [OpenClaw Kubernetes install guide](https://docs.openclaw.ai/install/kubernetes#kubernetes) is intentionally a minimal starting point: a Kustomize-based deployment, one namespace, one Gateway pod, a Service, a PVC, a ConfigMap, and a Secret. It is great for proving that OpenClaw runs in Kubernetes and for adapting the upstream manifests to your own cluster.

This repo starts from that same model and carries it further for long-running k3s/homelab use. It keeps the important upstream assumptions — single active Gateway, persistent OpenClaw state, Kubernetes Secrets, health checks, and safe-by-default local access — but adds the operational scaffolding you usually discover you need after OpenClaw becomes part of daily life.

Adopting this setup gives you:

- **Reproducibility:** the Gateway deployment, baseline config, runtime tools, workspace overlay, and managed project clones are declared in Git instead of living as one-off host state.
- **GitOps instead of manual redeploys:** Argo CD tracks the desired state, while Helm values make environment-specific changes cleaner than editing raw manifests.
- **Safer operations:** Helm rendering checks, health probes, rollback scripts, and the GitOps guard make changes more auditable and less “SSH into the box and hope.”
- **Persistent state with clearer ownership:** OpenClaw’s mutable home directory lives on a PVC, while the chart separates Git-managed workspace bootstrap from runtime-owned sessions, credentials, logs, and generated files.
- **Monitoring and recovery hooks:** Prometheus/Grafana, Alertmanager integration, Kopia backup jobs, and restore-drill docs are built in rather than bolted on later.
- **A cleaner path to production-ish homelab use:** SOPS-compatible secret workflows, image build automation, runtime tool bootstrapping, and disaster recovery are treated as first-class concerns from the start.

In short: the upstream Kubernetes docs show the clean minimal deployment; this repo is an opinionated k3s implementation of that pattern, hardened for running OpenClaw like durable personal infrastructure.

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
