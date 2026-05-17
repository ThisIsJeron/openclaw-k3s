# Forgejo/Actions runner notes

If you use Forgejo Actions or GitHub Actions self-hosted runners, avoid placing privileged build runners on the same host that runs your production k3s control plane.

Recommended posture:

- use a dedicated CI VM/host where possible
- use scoped registry credentials
- keep package-push tokens in Actions secrets, never in Git
- avoid workflows that can mutate the production cluster unless explicitly intended

For GitHub-hosted runners, the included `.github/workflows/preflight.yml` is usually enough for public-template validation.
