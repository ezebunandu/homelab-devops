data "vault_kv_secret_v2" "tailscale" {
  mount = "secret"
  name  = var.vault_secret_path
}

resource "null_resource" "tailscale" {
  for_each = var.hosts

  # Re-provision only when advertise_routes changes.
  # Auth key is one-time registration — rotating it in Vault does not trigger re-auth.
  triggers = {
    advertise_routes = coalesce(each.value.advertise_routes, "none")
  }

  connection {
    type  = "ssh"
    host  = each.value.ip
    user  = each.value.ssh_user
    agent = true
  }

  # Write auth key to a temp file so it is never exposed in remote-exec inline commands
  # or Terraform output. The script reads it once and deletes it immediately.
  provisioner "file" {
    content     = sensitive(data.vault_kv_secret_v2.tailscale.data["auth_key"])
    destination = "/tmp/ts-auth-key"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euo pipefail",

      # ── Install Tailscale if not present ───────────────────────────────────
      "if ! command -v tailscale >/dev/null 2>&1; then",
      "  echo '==> Installing Tailscale...'",
      "  curl -fsSL https://tailscale.com/install.sh | sh",
      "fi",

      "systemctl enable --now tailscaled",

      # ── Register with Tailscale if not already authenticated ───────────────
      "AUTH_KEY=$(cat /tmp/ts-auth-key); rm -f /tmp/ts-auth-key",
      "if ! tailscale status >/dev/null 2>&1; then",
      "  echo '==> Authenticating with Tailscale...'",
      each.value.advertise_routes != null
        ? "  tailscale up --auth-key=\"$AUTH_KEY\" --advertise-routes=${each.value.advertise_routes} --hostname=${each.key}"
        : "  tailscale up --auth-key=\"$AUTH_KEY\" --hostname=${each.key}",
      "else",

      # ── Already authenticated — update routes/hostname if they changed ──────
      "  echo '==> Tailscale already running, updating settings...'",
      each.value.advertise_routes != null
        ? "  tailscale set --advertise-routes=${each.value.advertise_routes}"
        : "  tailscale set --advertise-routes=",
      "fi",

      "echo '==> Tailscale status:'",
      "tailscale status",
    ]
  }
}
