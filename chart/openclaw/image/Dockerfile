# syntax=docker/dockerfile:1.7
#
# Bakes the runtime tools (jq, ssh, kubectl, helm, argocd, todoist-ts-cli,
# gogcli) and the channel plugins (@openclaw/discord, @openclaw/brave-plugin)
# into a single image so the openclaw Deployment no longer needs the
# install-runtime-tools / install-gogcli / install-channel-plugins init
# containers. Eliminating those removes the npm/curl dependency from every
# pod start and shrinks cold-start from minutes to seconds.
#
# Build:
#   docker buildx build \
#     --platform linux/amd64,linux/arm64 \
#     -t ghcr.io/YOUR_GITHUB_ORG/openclaw:<sha> \
#     -f chart/openclaw/image/Dockerfile \
#     chart/openclaw/image

ARG OPENCLAW_DIGEST=sha256:1af3f457a2d5a1d210f4d95634fa5da6e23f9c0ac7b52ef4bc38e2ecf09704fd
ARG GOGCLI_DIGEST=sha256:113e878719a30394049922364ee59daad5e7ffd70e78acd0b224c8be98c41831

# ---------------------------------------------------------------------------
# Stage 1: tools — assemble jq/ssh/kubectl/helm/argocd/todoist into /tools
#
# Mirrors the install-runtime-tools init container in
# chart/openclaw/templates/deployment.yaml so the resulting layout is
# byte-compatible with the existing /opt/openclaw-tools layout the gateway
# expects on PATH / LD_LIBRARY_PATH.
# ---------------------------------------------------------------------------
FROM debian:12-slim AS tools

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.34.2
ARG HELM_VERSION=v3.20.2
ARG ARGOCD_VERSION=v3.4.1
ARG TODOIST_VERSION=0.2.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl tar gzip jq openssh-client npm \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /tools/bin /tools/lib /tools/todoist /tools/tmp

COPY copy-binary.sh /usr/local/bin/copy-binary.sh
RUN chmod 0755 /usr/local/bin/copy-binary.sh \
 && /usr/local/bin/copy-binary.sh /tools jq \
 && /usr/local/bin/copy-binary.sh /tools ssh \
 && /usr/local/bin/copy-binary.sh /tools scp \
 && /usr/local/bin/copy-binary.sh /tools sftp

RUN npm install --omit=dev --prefix /tools/todoist "todoist-ts-cli@${TODOIST_VERSION}" \
 && ln -sf /opt/openclaw-tools/todoist/node_modules/.bin/todoist /tools/bin/todoist

RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
        -o /tools/bin/kubectl \
 && chmod 0755 /tools/bin/kubectl

RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" -o /tools/tmp/helm.tgz \
 && tar -xzf /tools/tmp/helm.tgz -C /tools/tmp \
 && install -m 0755 "/tools/tmp/linux-${TARGETARCH}/helm" /tools/bin/helm

RUN curl -fsSL "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${TARGETARCH}" \
        -o /tools/bin/argocd \
 && chmod 0755 /tools/bin/argocd

RUN rm -rf /tools/tmp

# ---------------------------------------------------------------------------
# Stage 2: gogcli — single-binary copy out of the upstream gogcli image
# ---------------------------------------------------------------------------
FROM ghcr.io/steipete/gogcli@${GOGCLI_DIGEST} AS gogcli

# ---------------------------------------------------------------------------
# Stage 3: final — openclaw + baked tools + baked channel plugins
#
# OPENCLAW_STATE_DIR is set to a build-only path so `node openclaw.mjs
# plugins install` writes into an image layer rather than the runtime PVC.
# The init container in the chart (seed-plugins) syncs this baked state
# into the PVC on pod start if a version drift is detected.
# ---------------------------------------------------------------------------
FROM ghcr.io/openclaw/openclaw@${OPENCLAW_DIGEST}

ARG DISCORD_PLUGIN_VERSION=2026.5.7
ARG BRAVE_PLUGIN_VERSION=2026.5.7

USER root

COPY --from=tools /tools/bin/  /opt/openclaw-tools/bin/
COPY --from=tools /tools/lib/  /opt/openclaw-tools/lib/
COPY --from=tools /tools/todoist/ /opt/openclaw-tools/todoist/
COPY --from=gogcli /usr/local/bin/gog /opt/openclaw-tools/bin/gogcli

RUN mkdir -p /opt/openclaw-baked-state
ENV OPENCLAW_STATE_DIR=/opt/openclaw-baked-state \
    OPENCLAW_HOME=/opt/openclaw-baked-home \
    HOME=/opt/openclaw-baked-home \
    PATH=/opt/openclaw-tools/bin:/usr/local/bin:/usr/bin:/bin \
    LD_LIBRARY_PATH=/opt/openclaw-tools/lib

RUN mkdir -p /opt/openclaw-baked-home \
 && node openclaw.mjs plugins install "@openclaw/discord@${DISCORD_PLUGIN_VERSION}" --force --pin \
 && node openclaw.mjs plugins install "@openclaw/brave-plugin@${BRAVE_PLUGIN_VERSION}" --force --pin \
 && node openclaw.mjs plugins registry --refresh \
 && chown -R 1000:1000 /opt/openclaw-baked-state /opt/openclaw-baked-home /opt/openclaw-tools

# Clear build-time state envs so the runtime container picks up the values
# the chart sets (OPENCLAW_STATE_DIR=/home/node/.openclaw, etc.). Leaving
# PATH / LD_LIBRARY_PATH in place so the baked tools work out of the box.
ENV OPENCLAW_STATE_DIR= \
    OPENCLAW_HOME= \
    HOME=/home/node

USER 1000
