# 🏠 Home Operations

<div align="center">

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.29-blue?style=for-the-badge&logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![ArgoCD](https://img.shields.io/badge/ArgoCD-GitOps-orange?style=for-the-badge&logo=argo&logoColor=white)](https://argoproj.github.io/cd/)
[![Renovate](https://img.shields.io/badge/Renovate-enabled-blue?style=for-the-badge&logo=renovatebot&logoColor=white)](https://github.com/renovatebot/renovate)

*GitOps-driven Kubernetes clusters for home infrastructure*

</div>

## 📖 Overview

This repository contains Infrastructure as Code (IaC) for my home Kubernetes clusters, managed using GitOps principles with ArgoCD. The setup supports multiple clusters with shared components and cluster-specific configurations.

### 🎯 Key Features

- **🔄 GitOps Workflow**: Complete GitOps setup using ArgoCD
- **🏗️ Multi-Cluster Support**: Manage multiple Kubernetes clusters from one repository
- **🔐 Secrets Management**: SOPS encryption with 1Password integration
- **📦 Helm + Kustomize**: Flexible application deployment and configuration
- **🚀 Automated Bootstrap**: Scripts for easy cluster initialization
- **🔧 Task Automation**: Task-based workflows for common operations
- **🤖 Dependency Updates**: Automated dependency management with Renovate Bot

## 🏗️ Architecture

```
┌─────────────────┐    ┌─────────────────┐
│   cluster01     │    │      omv        │
│                 │    │                 │
│  ┌───────────┐  │    │  ┌───────────┐  │
│  │  ArgoCD   │◄─┼────┼──┤  ArgoCD   │  │
│  └───────────┘  │    │  └───────────┘  │
│                 │    │                 │
│  Applications   │    │  Applications   │
└─────────────────┘    └─────────────────┘
         ▲                       ▲
         │                       │
         └───────────────────────┘
                     │
              ┌─────────────┐
              │   Git Repo  │
              │ (home-ops)  │
              └─────────────┘
```

## 📁 Repository Structure

```
.
├── 📂 clusters/                    # Cluster-specific configurations
│   ├── 📂 cluster01/              # Primary cluster
│   │   ├── 📂 apps/               # Applications for cluster01
│   │   └── 📂 bootstrap/          # Bootstrap configurations
│   └── 📂 omv/                   # Secondary cluster
│       └── 📂 apps/               # Applications for omv
├── 📂 components/                 # Shared Kubernetes components
│   ├── 📂 argo-system/           # ArgoCD configuration
│   ├── 📂 cert-manager/          # Certificate management
│   ├── 📂 default/               # Default namespace apps
│   ├── 📂 external-secrets/      # External secrets operator
│   ├── 📂 kube-system/           # System components
│   ├── 📂 longhorn-system/       # Storage system
│   ├── 📂 network/               # Networking components
│   └── 📂 common/                # Common configurations
├── 📂 helm/                      # Custom Helm charts
├── 📂 scripts/                   # Automation scripts
│   ├── 📜 bootstrap-apps.sh      # Cluster bootstrap script
│   └── 📂 lib/                   # Helper libraries
├── 📂 .taskfiles/                # Task definitions
├── 📄 Taskfile.yaml              # Main task configuration
└── 📄 makejinja.toml             # Template processing config
```

## 🚀 Getting Started

### Prerequisites

Ensure you have the following tools installed:

```bash
# Core tools
brew install kubernetes-cli helm kustomize
brew install argoproj/tap/argocd
brew install go-task/tap/go-task
brew install helmfile

# Security tools
brew install sops age
brew install 1password/tap/1password-cli

# Optional: Talos Linux tools (if using Talos)
brew install siderolabs/tap/talosctl
brew install budimanjojo/tap/talhelper
```

### 🔑 Setup Secrets

1. **Configure SOPS with age:**
   ```bash
   # Generate age key if you don't have one
   age-keygen -o ~/.config/sops/age/keys.txt

   # Export public key for .sops.yaml configuration
   age-keygen -y ~/.config/sops/age/keys.txt
   ```

2. **Configure 1Password CLI:**
   ```bash
   # Sign in to 1Password
   op signin

   # Verify access to kubernetes vault
   op vault list
   ```

### 🚀 Bootstrap a Cluster

1. **Bootstrap cluster applications:**
   ```bash
   # Bootstrap cluster01
   task bootstrap:apps CLUSTER_NAME=cluster01

   # Bootstrap omv cluster
   task bootstrap:apps CLUSTER_NAME=omv
   ```

2. **Manual ArgoCD access (if needed):**
   ```bash
   # Get ArgoCD admin password
   kubectl -n argo-system get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

   # Port forward to ArgoCD UI
   kubectl port-forward svc/argocd-server -n argo-system 8080:443
   ```

## 🔧 Common Operations

### Task Commands

```bash
# List all available tasks
task --list

# Force ArgoCD to sync all applications
task reconcile

# Bootstrap cluster applications
task bootstrap:apps CLUSTER_NAME=<cluster_name>
```

### Manual Operations

```bash
# Check ArgoCD application status
argocd app list

# Sync specific application
argocd app sync <app-name>

# Check cluster resources
kubectl get nodes,pods --all-namespaces
```

## 📦 Key Components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| **ArgoCD** | GitOps continuous delivery | `argo-system` |
| **Cert-Manager** | TLS certificate management | `cert-manager` |
| **External Secrets** | Secrets synchronization | `external-secrets` |
| **Traefik** | Ingress controller | `kube-system` |
| **Longhorn** | Distributed storage | `longhorn-system` |
| **Cilium** | Container networking | `kube-system` |
| **Homepage** | Dashboard application | `default` |
| **Syncthing** | File synchronization | `default` |
| **Garage** | S3-compatible object storage | `default` |

## 🔐 Security

- **Secrets Encryption**: All sensitive data encrypted with SOPS
- **External Secrets**: Integration with 1Password for secure secret management
- **TLS Certificates**: Automated certificate provisioning with cert-manager
- **Network Policies**: Implemented via Cilium for network security

## 🏗️ Adding New Applications

1. **Create component directory:**
   ```bash
   mkdir -p components/my-namespace/my-app
   ```

2. **Add Kustomization:**
   ```yaml
   # components/my-namespace/my-app/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   namespace: my-namespace
   resources:
     - namespace.yaml
     - http-route.yaml
   helmCharts:
     - name: my-app
       repo: https://charts.example.com
       version: "1.0.0"
       valuesFile: values.yaml
   ```

3. **Add to cluster configuration:**
   ```yaml
   # clusters/cluster01/apps/kustomization.yaml
   resources:
     - ../../components/my-namespace/my-app
   ```

## 🔄 GitOps Workflow

1. **Make changes** to application configurations in this repository
2. **Commit and push** changes to the main branch
3. **ArgoCD automatically detects** changes and syncs applications
4. **Monitor deployment** via ArgoCD UI or CLI

## 🤖 Automated Dependency Management

This repository uses **Renovate Bot** to automatically update dependencies:

### What Gets Updated
- **Helm Charts**: Automatically updates chart versions in `kustomization.yaml` files
- **Container Images**: Updates image tags in Kubernetes manifests
- **GitHub Releases**: Updates CRD URLs and tool versions in bootstrap scripts
- **Talos & Kubernetes**: Updates cluster platform versions

### Configuration
- **Main Config**: [`renovate.json`](renovate.json) - Comprehensive Renovate configuration
- **GitHub Specific**: [`.github/renovate.json5`](.github/renovate.json5) - Alternative config location
- **Dependency Dashboard**: Available in GitHub Issues for manual triggering

### Grouped Updates
Renovate intelligently groups related updates:
- **Cilium Ecosystem**: CNI, CLI, and related components
- **ArgoCD Stack**: Server, CLI, and ArgoCD applications
- **cert-manager**: Controller, webhook, and CRDs
- **Security Tools**: SOPS, external-secrets, and 1Password components

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test in a development environment
5. Submit a pull request

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<div align="center">

**⭐ Star this repo if you find it helpful!**

</div>
