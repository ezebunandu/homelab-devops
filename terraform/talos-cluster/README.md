# talos-cluster

Terraform module that provisions a 3-node Talos Linux cluster on the devops Proxmox node.

## Pre-flight: download the Talos image onto the PVE node

Run once on the Proxmox node before `terraform apply`. The `proxmox_virtual_environment_download_file`
resource has a known connectivity issue with the `query-url-metadata` API call, so the image is
downloaded manually instead.

```bash
SCHEMATIC="ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
VERSION="v1.12.6"
FILENAME="talos-${SCHEMATIC}-${VERSION}.img"

curl -L --progress-bar \
  "https://factory.talos.dev/image/${SCHEMATIC}/${VERSION}/metal-amd64.raw.zst" \
  | zstd -d > /var/lib/vz/template/iso/${FILENAME}
```

The schematic includes the `qemu-guest-agent` extension. If the Talos version is bumped,
update `VERSION` and re-run — the schematic ID stays the same.

## Apply

```bash
cp terraform.tfvars.example terraform.tfvars
cp .envrc.example .envrc   # fill in pve_api_token, then: direnv allow .
terraform init
terraform apply
```

## Post-apply

```bash
# Write kubeconfig
terraform output -raw kubeconfig > ~/.kube/config

# Verify nodes (will show NotReady until Cilium is installed)
kubectl get nodes -o wide
```

## Install Cilium

Nodes stay `NotReady` until a CNI is present.

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.57.30 \
  --set k8sServicePort=6443

kubectl -n kube-system rollout status daemonset/cilium
kubectl get nodes
```
