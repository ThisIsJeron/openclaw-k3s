# Backup Strategy

The old workspace Git repo backup is useful, but it is no longer enough by itself. The current OpenClaw deployment is a Kubernetes app with node-local PVC state, GitOps desired state, cron runtime state, Kubernetes Secrets, monitoring, and integration tokens/config.

Use a layered backup model.

## Goals

- Recover from accidental file deletion.
- Recover from a broken rollout or bad config change.
- Recover from a lost OpenClaw PVC.
- Recover from a lost k3s host.
- Prove recovery with regular restore drills.
- Keep secret values out of Git, Discord, and routine logs.

## Layers

### Layer 1 — Git source/config backup

Keep Git, but treat it as source/config history, not full disaster recovery.

Repos:

- GitOps repo: `openclaw-k3s`
- Workspace backup repo: `clawdbot-backup`

Good for:

- docs
- scripts
- memory files that are safe to back up
- GitOps chart/config
- drift review

Not sufficient for:

- raw Kubernetes Secrets
- full PVC/runtime state
- host rebuild
- proof that restore works

### Layer 2 — Redacted DR export bundle

Phase 1 creates a safe, redacted export bundle in the workspace. It captures recovery metadata without raw secret values:

- OpenClaw status snapshot
- cron scheduler status
- cron jobs and cron runtime state
- Kubernetes workload/status inventory
- PVC/PV inventory
- Argo CD app status
- Secret names and key names only, never secret values
- ConfigMap names and key names only
- workspace/GitOps git status snapshots

This bundle is intentionally small and Git-friendly. It should be safe for the existing workspace backup repo.

### Layer 3 — Encrypted PVC/runtime backups

Use an encrypted backup tool such as Kopia or Restic to back up the actual PVC/runtime data to object storage.

Recommended targets:

- Backblaze B2
- Cloudflare R2
- S3-compatible NAS/MinIO

Recommended initial retention:

- hourly for 24 hours
- daily for 14 days
- weekly for 8 weeks
- monthly for 6–12 months

This layer should cover runtime data that Git should not own.

### Layer 4 — Secrets recovery

Secrets need a dedicated strategy. Preferred long-term options:

1. **SOPS + age in GitOps** — recommended default for this setup.
   - Encrypted secret manifests live in Git.
   - The age private key lives offline/password-manager-side.
   - Rebuilds are deterministic without exposing plaintext in Git.
2. **External Secrets + 1Password/Vault/etc.**
   - Good if a dedicated secret manager already exists.
3. **Encrypted backup archive of secrets**
   - Simpler, but less GitOps-native.

Do not rely on manual secret recreation as the only recovery path.

### Layer 5 — Host/bootstrap recovery

Document and export enough host state to rebuild the platform:

- k3s version and install notes
- Argo CD install path
- firewall/SSH/systemd posture
- local-path PV location
- remaining host services, e.g. `openclaw-discord-slack-bridge.service`
- root SSH recovery path

This can be docs and inventory output; it does not need to be a full host image initially.

## Implementation phases

### Phase 1 — Redacted DR export bundle

Status: implemented.

Deliverables:

- Script: `/home/node/.openclaw/workspace/scripts/dr-export.sh`
- GitOps source: `chart/openclaw/workspace/scripts/dr-export.sh`
- Recurring cron job: `bc275b79-9e30-40a2-af8c-802be8d5609f` (`DR Export Bundle (Every 12h)`)
- Schedule: `20 3,15 * * *` America/Los_Angeles
- Latest bundle: `/home/node/.openclaw/workspace/dr-exports/latest/`
- Restore docs updated to reference the bundle

First manual export generated `dr-exports/latest/manifest.json` at `20260513T064701Z`.

### Phase 2 — Encrypted PVC backup

Status: planned.

Deliverables:

- choose Kopia or Restic
- choose B2/R2/S3 target
- create credentials as Kubernetes Secret
- scheduled backup job
- backup verification job
- restore drill from object storage into temporary PVC

### Phase 3 — Secrets hardening

Status: planned.

Deliverables:

- choose SOPS+age or External Secrets
- migrate critical OpenClaw secrets
- document key custody/recovery
- test secret restore into temporary namespace

### Phase 4 — Regular restore drills

Status: started.

Deliverables:

- monthly workspace/PVC restore drill
- post-major-change restore drill
- alert if latest successful drill is too old

## Success criteria

OpenClaw backup is considered mature when:

- latest DR export is less than 24 hours old
- encrypted PVC backup is less than 24 hours old
- secret recovery path has been tested
- monthly restore drill passes
- GitOps repo can recreate the app onto a fresh cluster
- recovery docs include exact commands and known gaps
