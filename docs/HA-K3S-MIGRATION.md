# HA k3s migration notes

Single-node k3s is simple and works well for many homelabs, but the node and its local storage remain a single point of failure.

A typical HA target looks like:

- 3 k3s server nodes
- a stable API endpoint or VIP for Kubernetes API access
- replicated storage or a tested restore path for OpenClaw PVC state
- ingress/load-balancing appropriate for your LAN/public exposure model

Migration checklist:

1. Prove off-host backups and restore before changing cluster topology.
2. Add new k3s server nodes according to upstream k3s HA docs.
3. Move workloads gradually and watch OpenClaw Gateway readiness.
4. Keep `replicaCount: 1` for OpenClaw Gateway unless active-active is explicitly safe for your setup.
5. Run a restore drill after the migration.
