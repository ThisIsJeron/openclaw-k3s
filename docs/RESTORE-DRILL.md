# Off-host PVC Restore Drill

This doc covers the **kopia → S3-compatible** backup track from
[BACKUP-STRATEGY.md](./BACKUP-STRATEGY.md) Phase 2. The chart's
`backup.enabled` toggle gates the backup CronJob; this doc covers
both the one-time setup and the regular restore drill that proves the
backups actually work.

The workspace-Git restore drill (Layer 1) is still tracked in
[DISASTER-RECOVERY.md](./DISASTER-RECOVERY.md).

## One-time backup setup

### 1. Pick a remote storage target

Recommended (in order of preference for this PoC):

- **Backblaze B2** (S3-compatible API). Cheapest egress for monthly
  restores. ~$5/month for 100 GB.
- **Cloudflare R2** (S3-compatible, free egress). Slightly more
  expensive storage but free to test-restore.
- **MinIO** on a NAS or another host you control. No cloud bill, but
  doesn't survive site loss.

Avoid AWS S3 unless egress costs are acceptable — backup verification
restores will hit the wallet.

### 2. Create the bucket

```bash
# B2 example
b2 create-bucket openclaw-backups allPrivate
# or via the B2 web console: Buckets → Create a Bucket

# R2 example (wrangler)
npx wrangler r2 bucket create openclaw-backups
```

### 3. Get the access credentials

For B2: Application Keys → "Add a New Application Key" → scope to the
bucket, copy `keyID` and `applicationKey`.

For R2: API Tokens → "Create API Token" → Object Read & Write on the
bucket, copy `Access Key ID` and `Secret Access Key`. Also note the R2
endpoint URL (`https://<account-id>.r2.cloudflarestorage.com`).

### 4. Create the Kubernetes Secret

```bash
# Generate a strong repository password — keep this safe. Without it,
# the encrypted backup cannot be restored.
KOPIA_PASSWORD="$(openssl rand -base64 32)"
echo "KOPIA_PASSWORD: $KOPIA_PASSWORD"
# Store this in your password manager NOW. The backup is useless
# without it.

kubectl -n openclaw create secret generic openclaw-backup-secrets \
  --from-literal=KOPIA_PASSWORD="$KOPIA_PASSWORD" \
  --from-literal=AWS_ACCESS_KEY_ID="<keyID>" \
  --from-literal=AWS_SECRET_ACCESS_KEY="<applicationKey>" \
  --from-literal=AWS_S3_ENDPOINT="https://s3.us-west-002.backblazeb2.com"
  # AWS_S3_ENDPOINT is required for B2/R2/MinIO. Omit for real AWS S3.
```

### 5. Flip the chart toggle

In `chart/openclaw/values.yaml`:

```yaml
backup:
  enabled: true
  repository: s3://openclaw-backups/k3s-prod
  # ...
```

Promote and apply:

```bash
./scripts/promote-prod.sh HEAD
git commit -am 'Enable kopia backup'
git push origin main
kubectl apply -f argocd/application.yaml
```

ArgoCD syncs, the CronJob is created. First run happens at the next
6-hour boundary (or trigger manually):

```bash
kubectl -n openclaw create job --from=cronjob/openclaw-backup \
  manual-backup-$(date +%Y%m%dT%H%M%S)
kubectl -n openclaw logs job/manual-backup-... -f
```

Expect ~30s for the first run (the openclaw PVC is small). The kopia
repo is created on the first invocation; subsequent runs reuse it.

## Restore drill (run monthly, and after any major migration)

Goal: prove a fresh PVC restored from the latest backup contains a
valid openclaw state directory. Don't touch production.

```bash
DRILL_NS="openclaw-drill-$(date +%Y%m%dT%H%M%S)"
kubectl create namespace "$DRILL_NS"

# Copy the backup secret into the drill namespace
kubectl get secret openclaw-backup-secrets -n openclaw -o yaml \
  | sed "s/namespace: openclaw/namespace: $DRILL_NS/" \
  | kubectl apply -f -

# Provision a temporary PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restore-target
  namespace: $DRILL_NS
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 10Gi
EOF

# Run a one-shot kopia restore Job
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: restore-drill
  namespace: $DRILL_NS
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: kopia
          image: kopia/kopia:0.18.1
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              export KOPIA_CONFIG_PATH=/tmp/kopia.config
              kopia repository connect s3 \\
                --bucket=openclaw-backups \\
                --prefix=k3s-prod/ \\
                --endpoint="\$AWS_S3_ENDPOINT"
              latest="\$(kopia snapshot list /backup-source --json \\
                | jq -r '.[] | .id' | tail -1)"
              echo "restoring \$latest"
              kopia snapshot restore "\$latest" /restore
              echo "restored size:"
              du -sh /restore
              echo "expected files:"
              ls -la /restore/.openclaw/openclaw.json /restore/.openclaw/workspace \\
                2>&1 | head -20
          env:
            - name: KOPIA_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: openclaw-backup-secrets
                  key: KOPIA_PASSWORD
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: openclaw-backup-secrets
                  key: AWS_ACCESS_KEY_ID
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: openclaw-backup-secrets
                  key: AWS_SECRET_ACCESS_KEY
            - name: AWS_S3_ENDPOINT
              valueFrom:
                secretKeyRef:
                  name: openclaw-backup-secrets
                  key: AWS_S3_ENDPOINT
          volumeMounts:
            - name: restore
              mountPath: /restore
      volumes:
        - name: restore
          persistentVolumeClaim:
            claimName: restore-target
EOF

kubectl -n "$DRILL_NS" wait --for=condition=complete job/restore-drill --timeout=600s
kubectl -n "$DRILL_NS" logs job/restore-drill

# Pass criteria:
#   - exit 0
#   - /restore/.openclaw/openclaw.json exists
#   - /restore/.openclaw/workspace is a directory
#   - restored size matches expected (current PVC is ~XX MB)

# Cleanup
kubectl delete namespace "$DRILL_NS"
```

Update [DISASTER-RECOVERY.md](./DISASTER-RECOVERY.md) "Last drill"
section with the result.

## Restoring production from a backup

Only do this if the live PVC is genuinely lost. Restoring overwrites
runtime state — credentials, sessions, workspace, etc.

```bash
# 1. Scale the gateway down so the PVC isn't being mutated.
kubectl -n openclaw scale deploy/openclaw --replicas=0
kubectl -n openclaw wait --for=delete pod -l app.kubernetes.io/name=openclaw --timeout=120s

# 2. Run a restore Job (same as the drill but with the real PVC).
#    Use claimName: openclaw-openclaw-state and mountPath: /restore.

# 3. After the Job completes, scale back up.
kubectl -n openclaw scale deploy/openclaw --replicas=1
kubectl -n openclaw rollout status deploy/openclaw --timeout=300s
```

Then run the post-restore checklist in [DISASTER-RECOVERY.md](./DISASTER-RECOVERY.md).

## What's NOT in this backup

This restores `/home/node/.openclaw` from the PVC. It does **not**
restore:

- Kubernetes Secrets (planned: [SECRETS-SOPS.md](./SECRETS-SOPS.md))
- The ArgoCD Application itself (planned: app-of-apps, task #19)
- k3s install state (host rebuild)

A full host-loss recovery still needs Git + Secrets recovery + this
restore drill in combination. See [DISASTER-RECOVERY.md](./DISASTER-RECOVERY.md)
Level 2.
