# Disaster recovery

This template assumes the Git repository declares desired cluster state and the OpenClaw PVC contains mutable runtime state.

Minimum recovery inputs:

- Git repository URL for this template
- Kubernetes access to a replacement k3s cluster
- off-host PVC backup repository credentials, if backups are enabled
- OpenClaw/channel/model secrets from your secret manager

Basic sequence:

1. Rebuild or provision k3s.
2. Install Argo CD.
3. Restore required Kubernetes Secrets.
4. Restore the OpenClaw PVC from backup, if available.
5. Apply/sync `argocd/apps/openclaw.yaml`.
6. Verify Gateway `/healthz` and `/readyz`.
7. Verify channel delivery in a low-risk test channel.

Keep a private drill log outside the public template, or append sanitized outcomes here.
