# ArgoCD app-of-apps

```
argocd/
├── application.yaml      # Legacy. The pre-migration single-Application setup.
│                          Keep until migration verified; then delete.
├── root/
│   ├── root.yaml         # Root Application — applied once via kubectl
│   └── README.md         # (this file)
└── apps/
    └── openclaw.yaml     # Child Application — replaces application.yaml
```

## Migration runbook

The cluster is currently running with the legacy `argocd/application.yaml`
as the only ArgoCD Application. Migration to app-of-apps is one-shot,
~5 min, and idempotent.

### Step 1: Apply the root

```bash
kubectl apply -f argocd/root/root.yaml
```

ArgoCD picks up the new `openclaw-root` Application. It will then sync
`argocd/apps/` and discover `argocd/apps/openclaw.yaml`, which has the
same `metadata.name: openclaw` / `metadata.namespace: argocd` as the
existing manual Application.

There are two outcomes here, depending on how ArgoCD resolves the
collision:

- **Adoption** (likely): ArgoCD applies `argocd/apps/openclaw.yaml`
  via server-side apply, taking ownership. The existing `openclaw`
  Application now appears under `openclaw-root` as a managed child.
- **Conflict** (possible): ArgoCD refuses to overwrite because the
  manual Application has different owners. In that case the next step
  resolves it.

Watch:

```bash
kubectl get app -n argocd
# Expect:
#   openclaw       Synced  Healthy
#   openclaw-root  Synced  Healthy
```

### Step 2: Verify or force-adopt

```bash
# Compare the spec of the live openclaw Application vs the file
kubectl get app openclaw -n argocd -o yaml | yq '.spec' > /tmp/live.yaml
yq '.spec' argocd/apps/openclaw.yaml > /tmp/file.yaml
diff -u /tmp/live.yaml /tmp/file.yaml
```

If the diff is empty, adoption worked — done.

If the diff is non-empty (conflict), force-apply the file:

```bash
kubectl apply -f argocd/apps/openclaw.yaml --force-conflicts \
  --server-side --field-manager=argocd-app-of-apps
```

Then verify the openclaw-root Application's `status.resources` lists
the openclaw Application as managed.

### Step 3: Delete legacy argocd/application.yaml

Once the live Application is sourced from `argocd/apps/openclaw.yaml`
and `openclaw-root` is reconciling it, the legacy file becomes a
duplicate source-of-truth.

```bash
git rm argocd/application.yaml
git commit -m 'Remove legacy ArgoCD Application; app-of-apps owns it'
git push origin main
# Then promote so the change reaches the cluster:
./scripts/promote-prod.sh HEAD
git commit -am 'Promote prod to <sha>'
git push origin main
# Note: there's nothing for kubectl apply to do here since the change
# is purely in the GitOps source, not in the ArgoCD-managed objects.
```

The promote-prod.sh script edits the `targetRevision` in
`argocd/application.yaml`. After step 3, it should edit
`argocd/apps/openclaw.yaml` instead — update the script accordingly
in the same commit that deletes the legacy file.

## Future children

Once app-of-apps is in place, additional Applications go under
`argocd/apps/` as separate YAML files. Candidates:

- `argocd-self.yaml` — ArgoCD installs itself from the upstream chart
  (closes the "argocd is down → rebuild manually" gap)
- `argo-rollouts.yaml` — installs argo-rollouts controller (prereq if
  task #11 is ever picked back up)
- `monitoring-extras.yaml` — additional monitoring resources beyond
  what kube-prometheus-stack pulls in
