# Optional gogcli integration

The chart has an optional `gogcli` init-container path for mounting Google Calendar CLI configuration from Kubernetes Secrets.

Public defaults keep this disabled:

```yaml
gogcli:
  enabled: false
```

If you enable it, create your own Secret keys and account-specific token paths. Do not commit Google credentials or token files.
