output "kubeconfig" {
  description = "Kubernetes admin kubeconfig. Write to ~/.kube/config or merge with kubecm."
  value       = talos_cluster_kubeconfig.cluster.kubeconfig_raw
  sensitive   = true
}

output "talosconfig" {
  description = "talosctl client config. Write to ~/.talos/config."
  value       = talos_machine_secrets.cluster.client_configuration
  sensitive   = true
}

output "node_ips" {
  description = "Node name → IP map."
  value       = { for name, node in var.nodes : name => node.ip }
}

output "cluster_vip" {
  description = "Kubernetes API VIP."
  value       = var.cluster_vip
}
