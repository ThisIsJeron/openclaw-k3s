#!/usr/bin/env bash
# Install or repair the ArgoCD repo-server ConfigManagementPlugin used to render
# the OpenClaw Helm chart plus SOPS-encrypted Secret manifests.
#
# This intentionally does not create argocd-age-key; generate/back up the age
# private key first, then create that Secret separately:
#   kubectl -n argocd create secret generic argocd-age-key \
#     --from-file=keys.txt=/root/.config/sops/age/openclaw.key
set -euo pipefail

NS="${ARGOCD_NAMESPACE:-argocd}"
DEPLOY="${ARGOCD_REPO_SERVER_DEPLOYMENT:-argocd-repo-server}"
ARGOCD_IMAGE="${ARGOCD_IMAGE:-quay.io/argoproj/argocd:v3.4.1}"
SOPS_VERSION="${SOPS_VERSION:-v3.10.2}"
AGE_VERSION="${AGE_VERSION:-v1.2.1}"

kubectl -n "$NS" get secret argocd-age-key >/dev/null

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: openclaw-helm-sops-cmp
  namespace: argocd
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: openclaw-helm-sops
    spec:
      generate:
        command: [sh, -c]
        args:
          - |
            set -eu
            helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
            helm dependency build . >&2
            helm template "${ARGOCD_APP_NAME}" . --namespace "${ARGOCD_APP_NAMESPACE}" --include-crds
            for f in secrets/*.enc.yaml; do
              [ -e "$f" ] || continue
              echo '---'
              sops --decrypt "$f"
            done
YAML

patch="$(python3 - <<PY
import json
argocd_image = ${ARGOCD_IMAGE@Q}
sops_version = ${SOPS_VERSION@Q}
age_version = ${AGE_VERSION@Q}
install_script = f'''set -eu
arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) sops_arch=amd64; age_arch=amd64 ;;
  aarch64|arm64) sops_arch=arm64; age_arch=arm64 ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac
cd /custom-tools
curl -fsSL "https://github.com/getsops/sops/releases/download/{sops_version}/sops-{sops_version}.linux.${{sops_arch}}" -o sops
chmod +x sops
curl -fsSL "https://github.com/FiloSottile/age/releases/download/{age_version}/age-{age_version}-linux-${{age_arch}}.tar.gz" -o /tmp/age.tgz
tar -xzf /tmp/age.tgz -C /tmp
cp /tmp/age/age /tmp/age/age-keygen /custom-tools/
chmod +x /custom-tools/age /custom-tools/age-keygen
'''
patch = {
  "spec": {"template": {"spec": {
    "initContainers": [{
      "name": "install-sops-tools",
      "image": "curlimages/curl:8.11.1",
      "imagePullPolicy": "IfNotPresent",
      "command": ["sh", "-c"],
      "args": [install_script],
      "volumeMounts": [{"name": "custom-tools", "mountPath": "/custom-tools"}],
    }],
    "containers": [
      {
        "name": "argocd-repo-server",
        "env": [
          {"name": "HELM_CACHE_HOME", "value": "/helm-working-dir"},
          {"name": "HELM_CONFIG_HOME", "value": "/helm-working-dir"},
          {"name": "HELM_DATA_HOME", "value": "/helm-working-dir"},
        ],
        "volumeMounts": [
          {"name": "helm-working-dir", "mountPath": "/helm-working-dir"},
          {"name": "plugins", "mountPath": "/home/argocd/cmp-server/plugins"},
        ],
      },
      {
        "name": "openclaw-helm-sops",
        "image": argocd_image,
        "imagePullPolicy": "IfNotPresent",
        "command": ["/var/run/argocd/argocd-cmp-server"],
        "env": [
          {"name": "PATH", "value": "/custom-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
          {"name": "SOPS_AGE_KEY_FILE", "value": "/etc/sops/age/keys.txt"},
          {"name": "HELM_CACHE_HOME", "value": "/helm-working-dir"},
          {"name": "HELM_CONFIG_HOME", "value": "/helm-working-dir"},
          {"name": "HELM_DATA_HOME", "value": "/helm-working-dir"},
        ],
        "securityContext": {
          "allowPrivilegeEscalation": False,
          "capabilities": {"drop": ["ALL"]},
          "readOnlyRootFilesystem": True,
          "runAsNonRoot": True,
          "seccompProfile": {"type": "RuntimeDefault"},
        },
        "volumeMounts": [
          {"name": "openclaw-helm-sops-cmp", "mountPath": "/home/argocd/cmp-server/config/plugin.yaml", "subPath": "plugin.yaml"},
          {"name": "var-files", "mountPath": "/var/run/argocd"},
          {"name": "plugins", "mountPath": "/home/argocd/cmp-server/plugins"},
          {"name": "cmp-tmp", "mountPath": "/tmp"},
          {"name": "helm-working-dir", "mountPath": "/helm-working-dir"},
          {"name": "age-key", "mountPath": "/etc/sops/age", "readOnly": True},
          {"name": "custom-tools", "mountPath": "/custom-tools", "readOnly": True},
        ],
      },
    ],
    "volumes": [
      {"name": "openclaw-helm-sops-cmp", "configMap": {"name": "openclaw-helm-sops-cmp", "defaultMode": 420}},
      {"name": "age-key", "secret": {"secretName": "argocd-age-key", "defaultMode": 256}},
      {"name": "custom-tools", "emptyDir": {}},
      {"name": "cmp-tmp", "emptyDir": {}},
      {"name": "helm-working-dir", "emptyDir": {}},
      {"name": "var-files", "emptyDir": {}},
      {"name": "plugins", "emptyDir": {}},
    ],
  }}}
}
print(json.dumps(patch))
PY
)"

kubectl -n "$NS" patch deployment "$DEPLOY" --type=strategic -p "$patch"
kubectl -n "$NS" rollout status deployment/"$DEPLOY" --timeout=180s

repo_pod="$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NS" exec "$repo_pod" -c openclaw-helm-sops -- sops --version
kubectl -n "$NS" exec "$repo_pod" -c openclaw-helm-sops -- age --version
kubectl -n "$NS" exec "$repo_pod" -c openclaw-helm-sops -- helm version --short
