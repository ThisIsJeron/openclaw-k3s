# Secrets in Git via SOPS + age

[BACKUP-STRATEGY.md](./BACKUP-STRATEGY.md) Phase 3. Today's secrets are
manual `kubectl create secret` invocations that aren't in Git — which
means rebuilding the cluster from scratch requires recreating each one
from a password manager. This doc covers the SOPS+age workflow that
moves those into Git as encrypted blobs.

The scheme: secret manifests live at `chart/openclaw/secrets/*.enc.yaml`,
encrypted with [sops](https://github.com/getsops/sops) using
[age](https://github.com/FiloSottile/age) recipients. Plaintext never
hits Git. ArgoCD decrypts during sync via a config-management plugin.

## What status this is at

- Scripts and helpers landed (see below).
- `.sops.yaml` repo config and the cluster-side decryption path are
  **not yet bootstrapped** — that's what this runbook walks through.
- Once bootstrapped, the existing manual secrets (`openclaw-secrets`,
  `workspace-git-credentials`, `openclaw-grafana-admin`,
  `openclaw-backup-secrets`) get migrated one at a time.

## Bootstrap

### 1. Install tooling locally

```bash
# macOS
brew install sops age

# Linux
# (see project READMEs for current install paths)
```

### 2. Generate an age key

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/openclaw.key
chmod 600 ~/.config/sops/age/openclaw.key

# Note the public key — it'll be in the file as a comment.
# Looks like: age1qhf2gpv...
grep '^# public key:' ~/.config/sops/age/openclaw.key
```

**Back up `~/.config/sops/age/openclaw.key` to your password manager.**
Anyone with this key can decrypt every secret in the repo. Losing it
means losing access to your own secrets (you'd need to re-create them
from the source-of-truth sources).

### 3. Create `.sops.yaml` at the repo root

```yaml
# .sops.yaml
creation_rules:
  - path_regex: chart/openclaw/secrets/.*\.enc\.yaml$
    encrypted_regex: ^(data|stringData)$
    age: age1qhf2gpv...   # paste your public key from step 2
```

Commit this — public keys are safe to expose.

```bash
git add .sops.yaml
git commit -m 'Bootstrap SOPS with age recipient'
```

### 4. Install the age private key in the cluster

ArgoCD's repo-server needs the age private key to decrypt secrets at
sync time. The cleanest pattern is a Secret in the `argocd` namespace
mounted into a config-management-plugin sidecar.

```bash
kubectl -n argocd create secret generic argocd-age-key \
  --from-file=keys.txt=$HOME/.config/sops/age/openclaw.key
```

### 5. Wire an ArgoCD ConfigManagementPlugin

Do **not** switch `argocd/apps/openclaw.yaml` to a plugin until the
repo-server plugin exists. If the Application references a missing plugin,
manifest generation fails and Argo cannot reconcile OpenClaw.

Current production bootstrap uses:

```bash
scripts/argocd-install-sops-cmp.sh
```

The live plugin behavior for this repo is:

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm dependency build .
helm template "$ARGOCD_APP_NAME" . \
  --namespace "$ARGOCD_APP_NAMESPACE" \
  --include-crds
for f in secrets/*.enc.yaml; do
  [ -e "$f" ] || continue
  echo '---'
  sops --decrypt "$f"
done
```

This intentionally treats encrypted secrets as Kubernetes manifests appended
after Helm rendering. It is safer here than `helm secrets template`, because
these files are Secret manifests, not encrypted Helm values files.

The sidecar/container image must contain compatible versions of:

- `helm`
- `sops`
- `age`

It also needs `SOPS_AGE_KEY_FILE=/etc/sops/age/keys.txt` and a read-only
mount of the `argocd-age-key` Secret at `/etc/sops/age`.

Once the CMP is installed and repo-server has rolled out, change the child
Application to use it:

```yaml
source:
  repoURL: https://github.com/YOUR_GITHUB_ORG/openclaw-k3s.git
  targetRevision: <promoted-sha>
  path: chart/openclaw
  plugin:
    name: openclaw-helm-sops
```

Then promote and verify Argo reaches `Synced Healthy` before migrating any
actual secret. Use your own age recipient, for example `age1REPLACE_WITH_YOUR_PUBLIC_RECIPIENT`. Do not reuse keys from someone else's deployment.

### 6. Guardrails

`chart/openclaw/secrets/.gitignore` only permits `*.enc.yaml`, `.gitignore`,
and `.gitkeep`. `scripts/preflight-gitops.sh` also fails if plaintext or
non-SOPS files appear under `chart/openclaw/secrets/`, and fails if encrypted
secret manifests exist without a root `.sops.yaml`.

Once the CMP is wired, encrypted files under
`chart/openclaw/secrets/*.enc.yaml` are applied by Argo after Helm rendering.
Migrate one Secret at a time and verify Argo health plus service behavior
after each migration.

## Day-to-day usage

### Encrypt a new secret

```bash
cat <<YAML | scripts/sops-encrypt-secret.sh - openclaw-secrets
apiVersion: v1
kind: Secret
metadata:
  name: openclaw-secrets
  namespace: openclaw
stringData:
  OPENAI_API_KEY: sk-...
  DISCORD_BOT_TOKEN: ...
YAML
```

Output: `chart/openclaw/secrets/openclaw-secrets.enc.yaml`. Commit it.

### Edit an existing encrypted secret

`sops` opens the encrypted file in your `$EDITOR` decrypted, re-encrypts
on save:

```bash
sops chart/openclaw/secrets/openclaw-secrets.enc.yaml
```

### Decrypt for inspection (don't commit the output)

```bash
sops --decrypt chart/openclaw/secrets/openclaw-secrets.enc.yaml
```

### Rotate the age key

1. Generate a new key (`age-keygen -o ~/.config/sops/age/openclaw.key.new`).
2. Add the new public key to `.sops.yaml` (keep the old one for now).
3. Re-encrypt all existing secrets:
   ```bash
   for f in chart/openclaw/secrets/*.enc.yaml; do
     sops updatekeys "$f"
   done
   ```
4. Commit the re-encrypted files.
5. Once everyone's on the new key, remove the old recipient from
   `.sops.yaml` and `sops updatekeys` everything again.

## Migration plan from current manual secrets

Migrate one at a time, lowest blast radius first.

1. `openclaw-alertmanager-discord` — affects Alertmanager Discord delivery
   only. This is the safest active secret to migrate first; verify by firing
   a synthetic alert and checking `your alert channel`.
2. `openclaw-grafana-admin` — affects Grafana login only.
3. `workspace-git-credentials` — affects workspace sync; failure is
   non-critical (gateway still boots, workspace stays stale).
4. `openclaw-backup-secrets` — affects backup CronJob only; migrate after
   Kopia exists.
5. `forgejo-registry` — affects image pulls; migrate only after a rollback
   path is clear.
6. `openclaw-grafana-ngrok` — only relevant if the ngrok path is enabled.
7. `openclaw-secrets` — affects the gateway itself. Migrate last,
   verify Discord/Slack still work after rollout.

For each one:

1. `kubectl get secret <name> -n openclaw -o yaml` — copy the data
   keys.
2. `scripts/sops-encrypt-secret.sh` to encrypt with current values.
3. Commit. The encrypted manifest is the new source of truth.
4. (Once helm-secrets CMP is wired) delete the manual secret; ArgoCD
   recreates it from the encrypted manifest.
5. Verify the running pod still has the env vars it needs.

## Disaster recovery implication

After this is fully wired:

- Losing the cluster = restore from backup ([RESTORE-DRILL.md](./RESTORE-DRILL.md))
  for PVC + clone the GitOps repo + supply the age private key from
  your password manager. ArgoCD bootstraps everything else.
- Losing the password manager AND the cluster = total loss; re-create
  every credential at its source (regenerate API keys, etc.).
- Losing only the password manager = generate a new age key, rotate
  per the steps above before the old key leaks.

Without SOPS (current state), every credential is "lose the cluster
without losing the password manager = you have to remember which
secrets existed and which keys they had."
