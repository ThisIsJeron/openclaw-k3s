# Reliability and Safe-Rollout Plan

This repo is now treated as the production GitOps control plane for OpenClaw
on k3s. The target posture is 99.999% practical availability: minimize single
points of failure, make rollouts reversible, keep secrets/backup state
recoverable, and isolate CI from production control-plane risk.

This doc tracks the in-flight work that makes that real — what's done, what's
next, and why the order matters.

The full original plan lives in `~/.claude/plans/robust-crunching-teacup.md`.
This doc is the user-facing summary of the same work, kept short on
purpose so it stays current.

## Where we are right now (2026-05-17)

- Gateway runs from a baked OpenClaw image with runtime tools preinstalled.
- GitOps deploys are pinned to promoted SHAs; pushing to `main` alone should
  not deploy production.
- ArgoCD app-of-apps structure is in place and the live `openclaw` Application
  is healthy.
- `gitops-guard` is enabled with LKG promotion and alerting hygiene.
- Alertmanager delivers Discord alerts through `your alert channel`.
- Forgejo Actions runner exists, but currently on the k3s control-plane host as
  a temporary bridge. Production target is a separate CI host/VM.
- Kopia backup CronJob is scaffolded but blocked on off-host bucket/keys.
- SOPS scaffolding exists but needs an age key and ArgoCD CMP before secrets can
  be migrated safely.
- HA k3s migration runbook exists and is now production work, blocked on
  additional reliable hosts and a maintenance window.

## Goal

Make changes to the gateway without serious outage, survive node loss without manual restore once HA is complete, and retain a tested restore path for corruption/operator-error scenarios.

## Plan, with current status

All tasks from the original plan are either **done in code** (sitting
in the repo, ready to deploy via the promotion flow) or **deferred
with explicit reasoning** (waiting on hardware / a specific failure
recurrence / a real need). Active user actions are listed at the
bottom.

| Status | # | Item |
|---|---|---|
| ✅ Done | 1 | Image bake |
| ✅ Done | 8 | Promotion-based GitOps: pin prod to SHA |
| ✅ Done | 9 | PR-time helm render-diff workflow (idle until runner) |
| ✅ Done | 12 | Resource limits, PDB, Alertmanager, baseline rules |
| ✅ Done | 13 | preflight-gitops.sh fix for bakedTools=true |
| ✅ Done | 14 | scripts/clean-stale-config.sh for stale PVC config |
| ✅ Scaffolded | 15 | SOPS secrets — encryption helper + bootstrap runbook |
| ✅ Scaffolded | 16 | Kopia backup CronJob + restore drill doc |
| ✅ Done | 17 | Forgejo runner installed (temporary on k3s host; move off-host next) |
| 🔒 Blocked | 18 | HA k3s migration (production goal; hardware-bound) |
| ✅ Scaffolded | 19 | ArgoCD app-of-apps structure + migration runbook |
| ✅ Done | 20 | Empty runtime-tools-on-elevated.patch deleted |
| ✅ Done | 21 | gitops-guard debounce — solved premature rollback |
| ✅ Done | 22 | deploy/lkg-guard-debounce healthz fix merged |
| Deferred | 10 | Guard rollback-stuck investigation — recurrence-gated |
| Deferred | 11 | Argo Rollouts BlueGreen — debounced guard sufficient |

## How to operate

### Promotion workflow (the main change)
Pushing to `main` does **not** deploy to prod. The flow is:

```bash
# Push your change to main as usual
git push origin main

# Promote when ready
./scripts/promote-prod.sh HEAD        # or a specific SHA / tag
# Script validates SHA is on main, updates argocd/application.yaml,
# prints commit/push/apply steps.

git commit -am 'Promote prod to <sha>'
git push origin main
kubectl apply -f argocd/application.yaml
# ArgoCD syncs prod to the promoted SHA. Watch:
kubectl get pods -n openclaw -l app.kubernetes.io/name=openclaw -w
```

After migrating to app-of-apps (`argocd/root/README.md`), the file
that `promote-prod.sh` edits becomes `argocd/apps/openclaw.yaml`.

### Image rebuild
Forgejo Actions can now run, but the current runner is temporarily on the k3s host. For production safety, move it to a dedicated CI host/VM before depending on automated image publishing for routine operations. Manual fallback:

```bash
# Once per laptop: docker login ghcr.io -u YOUR_GITHUB_USER
./scripts/build-image.sh
# Paste the printed digest into chart/openclaw/values.yaml.
# Then promote with the workflow above.
```

Rebuild when bumping a version in `chart/openclaw/image/Dockerfile`
(kubectl/helm/argocd/jq/gogcli/todoist) or a plugin version in
`seedPlugins.versions` (which also needs `DISCORD_PLUGIN_VERSION` /
`BRAVE_PLUGIN_VERSION` build args bumped).

### Emergency rollback
Guard's auto-rollback is active (~6–9 min). For manual rollback:

```bash
./scripts/promote-prod.sh <last-good-sha>
git commit -am 'Roll prod back to <sha>'
git push origin main
kubectl apply -f argocd/application.yaml
```

If the rollout is wedged behind a `CrashLoopBackOff` pod (#10 scenario):

```bash
kubectl delete deploy openclaw -n openclaw
kubectl -n argocd annotate app openclaw \
  argocd.argoproj.io/refresh=hard --overwrite
```

Wrapper scripts under `scripts/`: `emergency-rollback-openclaw.sh`,
`emergency-unpin-openclaw.sh` (legacy), `emergency-freeze-argocd.sh`.

### Clean stale PVC config

If init containers crash on a stale `plugins.load.paths` validation
(the better-gateway-dev pattern):

```bash
./scripts/clean-stale-config.sh
```

Idempotent. Replaces `/home/node/.openclaw/openclaw.json` with the
fresh ConfigMap-rendered copy, keeping a timestamped backup.

## What requires user action to fully complete

The following are sitting in the repo ready to use, but require a
human-side step the workflow can't do:

1. **Move Forgejo Actions runner off the k3s host** ([docs/FORGEJO-RUNNER.md](./FORGEJO-RUNNER.md))
   — provision a dedicated CI VM/host and re-register the runner there.
2. **Enable Kopia backup** ([docs/RESTORE-DRILL.md](./RESTORE-DRILL.md))
   — create bucket + secret, flip `backup.enabled: true`, promote, then run
   the first restore drill immediately.
3. **Bootstrap SOPS** ([docs/SECRETS-SOPS.md](./SECRETS-SOPS.md))
   — generate/back up age key, install in cluster, wire ArgoCD CMP, migrate
   lowest-blast-radius secrets first.
4. **HA k3s migration** ([docs/HA-K3S-MIGRATION.md](./HA-K3S-MIGRATION.md))
   — needs hardware and a migration window. This is now production work, not a
   someday PoC stretch.
5. **Repo slug cleanup**
   — desired public name is `openclaw-k3s`; rename Forgejo repo only with a
   coordinated Argo URL update + local remote update.

## Related docs

- [ARCHITECTURE.md](./ARCHITECTURE.md) — current cluster shape and components
- [GITOPS-ROLLBACK.md](./GITOPS-ROLLBACK.md) — guard design + failure modes
- [BACKUP-STRATEGY.md](./BACKUP-STRATEGY.md) — layered backup model
- [DISASTER-RECOVERY.md](./DISASTER-RECOVERY.md) — restore drill log
- [MONITORING.md](./MONITORING.md) — kube-prometheus-stack + Grafana access
- [FORGEJO-RUNNER.md](./FORGEJO-RUNNER.md) — runner install runbook
- [RESTORE-DRILL.md](./RESTORE-DRILL.md) — kopia backup setup + drill
- [SECRETS-SOPS.md](./SECRETS-SOPS.md) — encrypted-secrets-in-Git workflow
- [HA-K3S-MIGRATION.md](./HA-K3S-MIGRATION.md) — single-node → 3-node HA
