# Tailscale for remote admin access

We will use Tailscale as the lowest-ops remote admin path into the homelab, with the Traefik VM as the first subnet router advertising `192.168.57.0/24`. This gives off-LAN access to private homelab services without exposing them directly to the public internet, while keeping the initial rollout small: subnet router only, auth material stored in Vault, and split DNS/redundancy/direct Proxmox enrollment deferred until the basic route is proven.

## Considered options

- **Tailscale**: chosen because it provides reliable NAT traversal, good client support, and subnet routing with low operational burden.
- **Plain WireGuard**: viable fallback, but requires more manual key, route, DNS, and public endpoint management.
- **Headscale**: deferred because self-hosting the coordination plane before remote access exists creates bootstrap and operations overhead.
- **Direct Proxmox host enrollment**: deferred to minimize host-level blast radius; the first pass should prove access through the advertised LAN route.
- **Dedicated subnet-router VM/LXC**: deferred because the Traefik VM is already always-on and matches the current Terraform draft.

## Consequences

- Tailscale is a coordination-plane dependency for remote access, but local LAN operation remains independent of it.
- The first rollout validates reachability by IP/routed LAN access before adding split DNS.
- The Terraform module should be adjusted to enroll only the Traefik VM initially, not all Proxmox hosts.
- The Tailscale auth key belongs in Vault at the documented secret path; it must not be committed to Git.
