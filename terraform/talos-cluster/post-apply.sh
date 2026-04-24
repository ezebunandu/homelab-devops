#!/usr/bin/env bash
set -euo pipefail

# Write kubeconfig and point at node directly (VIP blocked by Firewalla ARP protection)
terraform output -raw kubeconfig > ~/.kube/config
kubectl config set-cluster devops --server=https://192.168.57.20:6443

echo "Waiting for nodes to be reachable..."
kubectl wait --for=condition=Ready node --all --timeout=120s 2>/dev/null || true

# Install Cilium with Talos-specific flags
helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
helm repo update

helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.57.20 \
  --set k8sServicePort=6443 \
  --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
  --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup

kubectl -n kube-system rollout status daemonset/cilium --timeout=5m
kubectl get nodes -o wide
