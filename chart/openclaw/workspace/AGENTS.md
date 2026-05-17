# AGENTS.md - Kubernetes Workspace

This workspace is managed by GitOps from the `openclaw-k3s` repository.

Rules:
- Treat `/home/node/.openclaw/workspace` as persistent state backed by the k3s PVC.
- Files declared in the Helm chart workspace overlay may be overwritten on rollout.
- Do not store secrets in GitOps-managed workspace files.
- Runtime state, credentials, logs, and bulky project data should stay on the PVC or in Kubernetes Secrets.
