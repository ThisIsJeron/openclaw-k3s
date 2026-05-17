# Secrets

Do not commit live Kubernetes Secrets to this template.

`chart/openclaw/secrets/` is reserved for SOPS-encrypted `*.enc.yaml` manifests. Create your own `.sops.yaml` from `.sops.yaml.example`, use your own age recipient, and keep the private key outside Git.
