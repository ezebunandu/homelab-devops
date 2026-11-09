# AGENTS.md

## Repo mission

This repo manages the homelab DevOps platform: Proxmox infrastructure, Talos Kubernetes, edge TLS, observability, remote access, and supporting runbooks/scripts.

Treat this as infrastructure code for a live home lab. Prefer small, reversible changes with explicit validation steps.

## Safety rules

- Do not commit secrets, tokens, kubeconfigs, Vault unseal keys, Terraform state, or generated credentials.
- Do not run destructive Terraform applies, node reboots, disk wipes, or cluster maintenance steps unless the user explicitly asks.
- Prefer `terraform plan` before proposing any `terraform apply`.
- For live infra work, state the blast radius before making changes.
- For Proxmox/Talos/Kubernetes maintenance, prefer one-node-at-a-time operations.
- Keep docs synchronized with operational reality. If a workaround or caveat changes, update the relevant README/runbook.

## Common commands

### Inspect issues

```bash
gh issue list --state open
gh issue view <number> --json number,title,body,labels,comments
```

### Terraform modules

Run Terraform from the module directory being changed, for example:

```bash
cd terraform/talos-cluster
terraform fmt
terraform validate
terraform plan
```

Other module directories include:

```text
terraform/traefik-vm/
terraform/talos-cluster/
terraform/pve-observability/
terraform/grafana-cloud/
terraform/grafana-alerts/
terraform/tailscale/
terraform/scratch-vm/
```

### Scripts

Operational scripts live in:

```text
scripts/
```

Read `scripts/README.md` before running a script. Some scripts are intended to run on a Proxmox node, the Traefik VM, or a workstation.

## Project conventions

- Terraform and scripts are the source of truth for infrastructure.
- Vendor charts should remain untouched; configure them through values in the GitOps repo.
- A new internal service should follow the paved path: CI → scan → Harbor → ArgoCD → Traefik.
- Use GitHub Issues for planned work.
- Use the active README status tables as the current roadmap unless an issue or user instruction supersedes them.

## Agent skills

### Issue tracker

Issues and specs are tracked in GitHub Issues for `ezebunandu/homelab-devops`. See `docs/agents/issue-tracker.md`.

### Triage labels

This repo uses the default Matt Pocock triage labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, and `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context repo: use root `GLOSSARY.md` and root `docs/adr/` for shared language and decisions. See `docs/agents/domain.md`.
