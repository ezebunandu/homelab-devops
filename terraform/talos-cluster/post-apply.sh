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

# Install MetalLB — L2 LoadBalancer IP announcements for LAN services.
# IP pool: 192.168.57.100-120 (excluded from Firewalla DHCP pool).
# Traefik VM routes service hostnames to these IPs.
echo ""
echo "==> Installing MetalLB..."
helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
helm repo update

kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace metallb-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite

helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --wait \
  --timeout 5m

# Wait for the webhook to be ready before applying CRs — the admission webhook
# rejects IPAddressPool/L2Advertisement if the controller isn't serving yet.
kubectl -n metallb-system wait --for=condition=Ready pod \
  -l component=controller --timeout=2m

kubectl apply -f metallb-config.yaml
echo "    MetalLB pool: 192.168.57.100-192.168.57.120"

# Install Longhorn distributed storage
# Requires: iscsi-tools + util-linux-tools extensions in the Talos schematic (baked into the image)
# and /dev/sdb partitioned + mounted at /var/lib/longhorn by the Talos machine config.
echo ""
echo "==> Installing Longhorn..."
helm repo add longhorn https://charts.longhorn.io 2>/dev/null || true
helm repo update

# Longhorn requires privileged pods (hostPath volumes, privileged containers).
# Create namespace and label it before Helm install so PodSecurity admission
# doesn't block the daemonset-controller from creating pods.
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace longhorn-system \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest \
  --overwrite

helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  --wait \
  --timeout 10m

echo ""
echo "==> Longhorn rollout status..."
kubectl -n longhorn-system rollout status deploy/longhorn-driver-deployer --timeout=5m
kubectl get pods -n longhorn-system

# Install ArgoCD — GitOps controller. App-of-apps bootstraps all platform services.
echo ""
echo "==> Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --wait \
  --timeout 5m \
  --set 'configs.params.server\.insecure=true' \
  --set server.service.type=LoadBalancer \
  --set 'server.service.annotations.metallb\.io/loadBalancerIPs=192.168.57.100'

kubectl -n argocd rollout status deploy/argocd-server --timeout=3m

echo ""
echo "==> ArgoCD ready."
echo "    Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo ""
echo "    UI: https://argocd.lab.hezebonica.ca (once Traefik route is in place)"
echo "    Or locally: kubectl port-forward svc/argocd-server -n argocd 8080:80"