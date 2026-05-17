# OpenClaw k8s workspace

This directory is reconciled into the gateway PVC by a Helm-managed initContainer before OpenClaw starts.

GitOps owns the baseline workspace overlay. Mutable runtime state still lives on the PVC.
