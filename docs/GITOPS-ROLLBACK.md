# GitOps Rollback and Outage Guard

OpenClaw is now managed by Argo CD and Helm. That gives repeatability, but it also means a bad GitOps change can break the primary interface operator uses to ask for help: Discord/Slack via OpenClaw.

The rollback system must therefore be **outside the OpenClaw gateway**. It must work even when the OpenClaw pod is stuck in `Init:Error`, `CrashLoopBackOff`, or failing readiness.

## Best-practice shape for this personal cluster

For a personal single-node cluster, do **not** start with a full always-on staging clone. It adds cost/complexity and can create duplicate side effects for Discord, cron jobs, bank sync, browser sessions, etc.

Use this instead:

1. **Preflight before sync**
   - Helm render/lint.
   - Kubernetes server-side dry-run.
   - Workspace-sync dirty-tree simulation.
   - Optional temporary namespace smoke test for high-risk chart changes.
2. **Automated health gate after sync**
   - Watch Argo app health/sync status.
   - Watch OpenClaw Deployment availability.
   - Check `/readyz` from inside the cluster.
   - Detect initContainer failures quickly.
3. **Last-known-good (LKG) revision tracking**
   - Promote a Git SHA to LKG only after it has been healthy for a stability window.
   - Store LKG outside the gateway, e.g. a Kubernetes ConfigMap.
4. **Automated rollback by pinning Argo to LKG**
   - If the latest GitOps revision breaks OpenClaw, patch the Argo Application `targetRevision` to the LKG SHA and sync.
   - Do not rely on committing a revert while the system is down.
5. **Out-of-band alerting**
   - Notify operator via a Discord webhook or other direct channel that does not depend on the OpenClaw gateway.
6. **Break-glass host command**
   - A host-side script using `/etc/rancher/k3s/k3s.yaml`, so it works over SSH even if OpenClaw is dead.

Permanent staging can come later if needed, but the first priority is automatic detection and rollback for production itself.

## Why pin Argo instead of git revert?

During an outage, the safest rollback path is to patch Argo directly:

```bash
kubectl -n argocd patch application openclaw --type=merge \
  -p '{"spec":{"source":{"targetRevision":"<known-good-sha>"}}}'
```

Then sync that exact revision.

This is better than immediately pushing a git revert because:

- it does not require Git credentials during the outage;
- it works even if the Git server is unhealthy;
- it is fast and deterministic;
- it prevents Argo self-heal from reapplying the broken `main` revision;
- it can be automated by a small watchdog with limited RBAC.

After recovery, a human/agent should decide whether to:

- revert the bad commit on `main`, then unpin `targetRevision` back to `main`; or
- fix forward, then unpin after validation.

## Failure modes to detect

The outage guard should consider rollback when **production OpenClaw is unavailable because of GitOps reconciliation**.

Hard failure signals:

- Argo app `openclaw` is `Degraded` for more than 2–3 minutes.
- OpenClaw Deployment has `Available=False` for more than 2–3 minutes.
- OpenClaw pod is stuck in:
  - `Init:Error`
  - `CrashLoopBackOff`
  - `ImagePullBackOff`
  - `CreateContainerConfigError`
- Any initContainer exits non-zero after a new Argo revision.
- In-cluster `http://openclaw.openclaw.svc.cluster.local:18789/readyz` fails for more than 2–3 minutes after rollout.

Soft failures that should alert but **not automatically roll back**:

- A single cron job fails.
- A non-critical integration fails, e.g. Actual Budget remote-file transient.
- Monitoring public tunnel rotates or fails while the gateway is healthy.
- A smoke test fails because of a third-party API outage.

## Last-known-good promotion

A revision should be promoted to LKG only after all are true:

- Argo app `openclaw` is `Synced` and `Healthy`.
- OpenClaw Deployment is available.
- `/readyz` succeeds from inside the cluster.
- OpenClaw pod has not restarted during the stability window.
- No initContainer failures occurred for the revision.
- Stability window elapsed: start with 10 minutes.

Store LKG in a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-last-known-good
  namespace: openclaw
data:
  revision: "<git-sha>"
  promotedAt: "<iso8601>"
  argoHealth: "Healthy"
  argoSync: "Synced"
  readyz: "ok"
  notes: "auto-promoted by gitops guard"
```

Keep at least the previous LKG too:

```yaml
data:
  revision: "<current-good-sha>"
  previousRevision: "<previous-good-sha>"
```

## Automated rollback flow

1. Watch current Argo revision.
2. If revision changes, mark it as `candidate`.
3. Run health checks for the stability window.
4. If healthy, promote candidate to LKG.
5. If hard failure occurs before promotion:
   1. read `openclaw-last-known-good.data.revision`;
   2. patch Argo Application `spec.source.targetRevision` to that SHA;
   3. trigger/sync Argo;
   4. wait for Deployment available and `/readyz` OK;
   5. notify operator out-of-band;
   6. leave Argo pinned to LKG until a human/agent fixes `main` and unpins.

Pseudo-command sequence:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

LKG="$(kubectl -n openclaw get configmap openclaw-last-known-good \
  -o jsonpath='{.data.revision}')"

kubectl -n argocd patch application openclaw --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"$LKG\"}}}"

kubectl -n argocd annotate application openclaw \
  argocd.argoproj.io/refresh=hard --overwrite

# Depending on available Argo tooling, either let automated sync apply the pin,
# or use argocd CLI / controller-supported sync path.
kubectl -n openclaw rollout status deploy/openclaw --timeout=300s
```

## Break-glass manual runbook

If automation fails, SSH to host `192.0.2.10` and run from the host, not inside the OpenClaw pod:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n argocd get application openclaw -o wide
kubectl -n openclaw get pod
kubectl -n openclaw describe pod -l app.kubernetes.io/name=openclaw
kubectl -n openclaw logs deploy/openclaw --all-containers --tail=200
```

Rollback to LKG:

```bash
LKG="$(kubectl -n openclaw get configmap openclaw-last-known-good \
  -o jsonpath='{.data.revision}')"

kubectl -n argocd patch application openclaw --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"$LKG\"}}}"

kubectl -n argocd annotate application openclaw \
  argocd.argoproj.io/refresh=hard --overwrite

kubectl -n openclaw rollout status deploy/openclaw --timeout=300s
```

Unpin after `main` is fixed:

```bash
kubectl -n argocd patch application openclaw --type=merge \
  -p '{"spec":{"source":{"targetRevision":"main"}}}'

kubectl -n argocd annotate application openclaw \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Preflight checks for future GitOps changes

Every GitOps change should pass:

```bash
helm dependency build chart/openclaw
helm lint chart/openclaw
helm template openclaw chart/openclaw --namespace openclaw > /tmp/openclaw-rendered.yaml
kubectl apply --dry-run=server -f /tmp/openclaw-rendered.yaml
```

Workspace-sync changes also need a dirty-tree simulation, because the previous outage was caused by initContainer checkout behavior against a dirty PVC checkout:

```bash
tmp="$(mktemp -d)"
git clone --depth 1 https://github.com/YOUR_GITHUB_ORG/openclaw-k3s.git "$tmp/repo"
cd "$tmp/repo"
echo dirty >> README.md
mkdir -p docs
printf 'untracked\n' > docs/UNTRACKED.md
# Run the rendered workspace-sync logic against this dirty tree and prove it exits 0.
```

## Staging recommendation

For this personal cluster:

- Do **not** run a full permanent staging OpenClaw by default.
- Do run temporary staging/preflight jobs for high-risk changes.
- If a staging OpenClaw is later added, it must have:
  - Discord/Slack disabled or pointed to test channels only;
  - cron disabled;
  - finance/bank sync disabled;
  - separate workspace/PVC;
  - separate secrets;
  - no access to production node/browser sessions.

A small automated guard plus LKG rollback gives better reliability-per-complexity than a permanent staging clone right now.

## Implementation status

Implemented in GitOps after this design was accepted:

- `openclaw-last-known-good` ConfigMap is created/maintained outside Argo-managed manifests so Argo does not overwrite mutable LKG data.
- Initial LKG was bootstrapped manually while production was healthy at revision `c96595d`.
- `openclaw-gitops-guard` runs as a Kubernetes CronJob outside the OpenClaw gateway path.
- Guard schedule: every minute.
- Guard rollback grace: `180` seconds.
- Guard promotion stability window: `600` seconds.
- Guard alerts use the Discord Bot API directly with `DISCORD_BOT_TOKEN` from `openclaw-secrets`, so alerts do not depend on the OpenClaw gateway being alive.
- Break-glass scripts are stored under repo `scripts/`:
  - `emergency-freeze-argocd.sh`
  - `emergency-rollback-openclaw.sh <sha|lkg>` — patches targetRevision, requests immediate sync, waits for rollout, verifies pod state and `/readyz`; set `VERIFY_SLACK=1` to include the Slack bridge canary.
  - `emergency-unpin-openclaw.sh [targetRevision]`
  - `slack-bridge-health.sh [--canary]` — checks bridge process/state freshness without sending messages by default; `--canary` posts controlled Slack/Discord test messages.
- GitOps preflight is stored under `scripts/preflight-gitops.sh` and wired into `.github/workflows/preflight.yml`:
  - runs `helm lint` and `helm template`;
  - extracts rendered `ensure_plugin` installs;
  - fails if native channels such as `@openclaw/slack` are treated as plugins;
  - verifies each rendered npm plugin package/version exists via `npm view`.
- Guard hardening after the Slack/native-channel incident:
  - detects init-container crash states including `Init:CrashLoopBackOff` and nonzero init exits;
  - tracks the observed Argo revision from synced revision, operation result revision, or targetRevision;
  - pinned revisions are not promoted to LKG, but unhealthy non-LKG pins can still roll back;
  - rollback requests both a hard refresh and a best-effort immediate Argo sync operation.

Still planned:

1. Add a chaos test that intentionally points a temporary app at a broken revision and proves rollback behavior without touching production.
2. Revisit staging only after the guard has proven itself.

## Non-goals for first implementation

- Full HA OpenClaw.
- Multi-node Kubernetes.
- A second always-on production-like OpenClaw.
- Automatic rollback for third-party service failures.
- Automatic git revert commits.

## Observed failure modes (2026-05-13)

The guard caused user-visible outages in **both** of the two deploys it
saw on 2026-05-13. Worth recording before re-enabling it.

### Failure 1: rollback patch didn't take effect

During the first `bakedTools=true` deploy, the gateway crashed in
`seed-plugins` init (missing `OPENCLAW_CONFIG_PATH`, fixed in `afe58be`).
The guard correctly detected unhealth and patched
`spec.source.targetRevision` to LKG `b3526c8`. ArgoCD acknowledged the
patch and flagged the app `OutOfSync` / `Degraded`, but did **not**
apply the LKG manifest — the Deployment kept the broken spec and the
pod kept crashlooping for ~10 min.

Suspected cause: `strategy: Recreate` + a pod stuck in
`Init:CrashLoopBackOff` blocks the rollout from progressing, and
ArgoCD's automated sync doesn't force progress through that state.

Manual recovery: `kubectl delete deploy openclaw -n openclaw` plus
`kubectl -n argocd annotate app openclaw argocd.argoproj.io/refresh=hard`
— within ~60s the Deployment was recreated from the LKG manifest.

### Failure 2: premature rollback before cold start completed

After the seed-plugins fix landed in `afe58be`, the new pod was
healthy and serving Discord. But the gateway's cold start (image pull
on a node without cached layers, plus `seed-plugins`' `plugins registry
--refresh`) took longer than `rollbackAfterSeconds: 180`. The guard
rolled back to `b3526c8` mid-startup — Failure 1 then chained.

### Action items

- `rollbackAfterSeconds: 180` is too aggressive. Should be ≥600 to give
  cold-start enough slack, especially on a cold node.
- Guard's rollback path should be extended to also `kubectl delete
  deploy` if its patch doesn't take effect within N seconds — or be
  replaced by Argo Rollouts whose `prePromotionAnalysis` failure
  doesn't require ArgoCD reconciliation to recover.
- Until either is in place, the guard CronJob is **suspended**:
  `kubectl patch cronjob openclaw-gitops-guard -n openclaw --type merge
  -p '{"spec":{"suspend":true}}'`.
- See [RELIABILITY-PLAN.md](./RELIABILITY-PLAN.md) tasks #10, #11, #21.
