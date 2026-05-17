# Monitoring

This repo deploys the OpenClaw monitoring stack through the Helm chart.

## Current production status — 2026-05-13

Monitoring is live in the `openclaw` namespace.

Verified state:

- Argo CD app `openclaw`: `Synced`, `Healthy`, revision `a901230`
- Grafana deployment `openclaw-grafana`: running
- Prometheus deployment/service `openclaw-monitoring-prometheus`: running and ready
- Monitoring operator `openclaw-monitoring-operator`: running
- `kube-state-metrics`: running
- Public tunnel deployment `grafana-cloudflared`: running
- Grafana health: OK, version `13.0.1`
- Grafana dashboards: `27`
- Prometheus active targets: `11 up`, `0 down`

Current public access is via a Cloudflare quick tunnel, not ngrok. The active URL is emitted by the `grafana-cloudflared` pod logs and can rotate when the pod restarts:

```bash
kubectl -n openclaw logs deploy/grafana-cloudflared \
  | grep -o 'https://[^ ]*trycloudflare.com' \
  | tail -1
```

Important security note: the current live tunnel points directly at Grafana, so Grafana login is the active protection layer. A previous implementation note mentioned an additional Basic Auth proxy, but the current `grafana-cloudflared` deployment args point directly to `http://openclaw-grafana.openclaw.svc.cluster.local:80`. If public access remains enabled long-term, prefer restoring an outer Basic Auth proxy or moving to a named Cloudflare Tunnel with Cloudflare Access.

## Components

- `kube-prometheus-stack` Helm dependency, controlled by `kube-prometheus-stack.enabled`
- Prometheus for cluster/app metrics
- Grafana for dashboards
- Optional Cloudflare quick tunnel for public Grafana access
- Optional ngrok tunnel support if an ngrok token is available

Public access is disabled by default. Grafana anonymous auth is not enabled; use the admin credentials from the Kubernetes Secret below.

## Required secrets

Before enabling/syncing monitoring, create the Grafana admin secret in the OpenClaw namespace:

```bash
kubectl -n openclaw create secret generic openclaw-grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password='<strong password>'
```

The public URL is emitted in the `grafana-cloudflared` pod logs:

```bash
kubectl -n openclaw logs deploy/grafana-cloudflared | grep -o 'https://[^ ]*trycloudflare.com'
```

For ngrok access instead, create:

```bash
kubectl -n openclaw create secret generic openclaw-grafana-ngrok \
  --from-literal=NGROK_AUTHTOKEN='<ngrok authtoken>'
```

Then set `monitoring.publicAccess.cloudflared.enabled=false` and `monitoring.publicAccess.ngrok.enabled=true` in `chart/openclaw/values.yaml`. Optionally set `monitoring.publicAccess.ngrok.domain` for a reserved ngrok domain.

Public access exposes Grafana directly through the selected tunnel. Grafana still requires its own login.

## Local validation

```bash
helm dependency build chart/openclaw
helm lint chart/openclaw
helm template openclaw chart/openclaw --namespace openclaw > /tmp/openclaw-rendered.yaml
helm template openclaw chart/openclaw --namespace openclaw \
  --set monitoring.publicAccess.ngrok.enabled=true \
  > /tmp/openclaw-rendered-ngrok.yaml
```

Cluster dry-run, if connected to the k3s API:

```bash
kubectl apply --dry-run=server -f /tmp/openclaw-rendered.yaml
```

## Access

Internal Grafana service:

```bash
kubectl -n openclaw port-forward svc/openclaw-grafana 3000:80
```

Then open <http://localhost:3000> and log in with the secret-backed admin credentials.
