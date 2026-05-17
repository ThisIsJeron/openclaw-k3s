# Runtime Tools

> **Current default**: runtime tools and channel plugins are **baked into
> the openclaw image** (`chart/openclaw/image/Dockerfile`, built via
> `scripts/build-image.sh`, see [RELIABILITY-PLAN.md](./RELIABILITY-PLAN.md)).
> Under `image.bakedTools: true` (the default in production), the
> `install-runtime-tools` and `install-gogcli` init containers are
> **skipped** — `/opt/openclaw-tools/` is part of the image. This doc
> describes the legacy `bakedTools: false` fallback path, which remains
> as the emergency rollback if a baked image is broken.

The OpenClaw base image is intentionally minimal. Under the legacy
fallback path, the chart installs the helper CLIs needed by workspace
automation into an `emptyDir` at pod startup and mounts them into the
Gateway container at:

```text
/opt/openclaw-tools/bin
```

The Gateway and plugin-install initContainer prepend that directory to `PATH` and set:

```text
LD_LIBRARY_PATH=/opt/openclaw-tools/lib
GOG_KEYRING_BACKEND=file
```

## Installed tools

Configured in `chart/openclaw/values.yaml:runtimeTools`:

- `todoist` — installed from pinned npm package `todoist-ts-cli`; uses `TODOIST_API_TOKEN` from env first, then `/home/node/.config/todoist-cli/config.json`.
- `jq` — Debian package, used by email triage scripts.
- `ssh`, `scp`, `sftp` — Debian `openssh-client`, used by W11/browser helper scripts and ad-hoc ops.
- `kubectl` — downloaded from the pinned Kubernetes release.
- `helm` — downloaded from the pinned Helm release.
- `argocd` — downloaded from the pinned Argo CD release.

`gogcli` is still managed by the chart's dedicated `gogcli:` initContainers because it also needs Kubernetes Secret-backed config/keyring rendering.

## Secret expectations

The Gateway container already imports `openclaw-secrets` via `envFrom`. For these tools, expected keys are:

- `TODOIST_API_TOKEN` for `todoist-ts-cli`.
- `GOG_KEYRING_PASSWORD` and the configured `gogcli.secretFiles[]` keys for Google CLI auth.

## Tradeoff

Originally this kept the PoC on the pinned upstream OpenClaw image
while restoring old host-runtime CLI parity. As of 2026-05-13 the
default has flipped: the same tools are baked into a custom image
(`chart/openclaw/image/Dockerfile`) for faster pod startup (~60s vs
~4–6 min) and to remove the npm/curl network dependency from every pod
start. This file documents the legacy path that remains behind
`image.bakedTools: false`.
