# 🚀 Talos Linux Cluster Provisioning Guide

This guide will walk you through setting up a Talos Linux Kubernetes cluster using this home-ops repository.

## 📋 Prerequisites

Before starting, ensure you have:

- **Hardware**: 3+ nodes with minimum 4 cores, 16GB RAM, 256GB SSD each
- **Network**: All nodes on the same network with internet access
- **Workstation**: macOS/Linux with required CLI tools installed
- **Cloudflare Account**: For DNS and tunnel management
- **GitHub Account**: For repository management

## 🚀 Let's Go

There are **5 stages** outlined below for completing this project, make sure you follow the stages in order.

### Stage 1: Machine Preparation

> [!IMPORTANT]
> If you have **3 or more nodes** it is recommended to make 3 of them controller nodes for a highly available control plane. This project configures **all nodes** to be able to run workloads. **Worker nodes** are therefore **optional**.
>
> **Minimum system requirements**
>
> | Role    | Cores    | Memory        | System Disk               |
> |---------|----------|---------------|---------------------------|
> | Control/Worker | 4 | 16GB | 256GB SSD/NVMe |

1. Head over to the [Talos Linux Image Factory](https://factory.talos.dev) and follow the instructions. Be sure to only choose the **bare-minimum system extensions** as some might require additional configuration and prevent Talos from booting without it. You can always add system extensions after Talos is installed and working.

2. This will eventually lead you to download a Talos Linux ISO (or for SBCs a RAW) image. Make sure to note the **schematic ID** you will need this later on.

3. Flash the Talos ISO or RAW image to a USB drive and boot from it on your nodes.

4. Verify with `nmap` that your nodes are available on the network. (Replace `192.168.1.0/24` with the network your nodes are on.)

    ```sh
    nmap -Pn -n -p 50000 192.168.1.0/24 -vv | grep 'Discovered'
    ```

### Stage 2: Local Workstation

> [!TIP]
> It is recommended to set the visibility of your repository to `Public` so you can easily request help if you get stuck.

1. Create a new repository by clicking the green `Use this template` button at the top of this page, then clone the new repo you just created and `cd` into it. Alternatively you can use the [GitHub CLI](https://cli.github.com/) ...

    ```sh
    export REPONAME="home-ops"
    gh repo create $REPONAME --template vikaspogu/home-ops --disable-wiki --public --clone && cd $REPONAME
    ```

2. **Install** the [Mise CLI](https://mise.jdx.dev/getting-started.html#installing-mise-cli) on your workstation.

3. **Activate** Mise in your shell by following the [activation guide](https://mise.jdx.dev/getting-started.html#activate-mise).

4. Use `mise` to install the **required** CLI tools:

    ```sh
    mise trust
    pip install pipx
    mise install
    mise run deps
    ```

   📍 _**Having trouble installing the tools?** Try unsetting the `GITHUB_TOKEN` env var and then run these commands again_

   📍 _**Having trouble compiling Python?** Try running `mise settings python.compile=0` and then run these commands again_

5. Logout of GitHub Container Registry (GHCR) as this may cause authorization problems when using the public registry:

    ```sh
    docker logout ghcr.io
    helm registry logout ghcr.io
    ```

### Stage 3: Cloudflare configuration

> [!WARNING]
> If any of the commands fail with `command not found` or `unknown command` it means `mise` is either not install or configured incorrectly.

1. Create a Cloudflare API token for use with cloudflared and external-dns by reviewing the official [documentation](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/) and following the instructions below.

   - Click the blue `Use template` button for the `Edit zone DNS` template.
   - Name your token `kubernetes`
   - Under `Permissions`, click `+ Add More` and add permissions `Zone - DNS - Edit` and `Account - Cloudflare Tunnel - Read`
   - Limit the permissions to a specific account and/or zone resources and then click `Continue to Summary` and then `Create Token`.
   - **Save this token somewhere safe**, you will need it later on.

2. Create the Cloudflare Tunnel:

    ```sh
    cloudflared tunnel login
    cloudflared tunnel create --credentials-file cloudflare-tunnel.json kubernetes
    ```

### Stage 4: Cluster configuration

1. Generate the config files from the sample files:

    ```sh
    # This step may not be needed as the repository already contains configuration files
    # If you need to generate new configs, follow the talhelper documentation
    ```

2. Fill out the Talos configuration files in `clusters/talos/bootstrap/os/` directory:
   - `talconfig.yaml` - Talos cluster configuration
   - `talenv.yaml` - Talos environment variables
   - `nodes.yaml` - Node definitions

3. Generate Talos configuration files:

    ```sh
    task talos:generate-config
    ```

4. Push your changes to git:

   📍 _**Verify** all the `clusters/**/*.sops.*` files are **encrypted** with SOPS_

    ```sh
    git add -A
    git commit -m "chore: initial commit :rocket:"
    git push
    ```

> [!TIP]
> Using a **private repository**? Make sure to paste the public key from `github-deploy.key.pub` into the deploy keys section of your GitHub repository settings. This will make sure Argo has read/write access to your repository.

### Stage 5: Bootstrap Talos, Kubernetes, and Argo

> [!WARNING]
> It might take a while for the cluster to be setup (10+ minutes is normal). During which time you will see a variety of error messages like: "couldn't get current server API group list," "error: no matching resources found", etc. 'Ready' will remain "False" as no CNI is deployed yet. **This is a normal.** If this step gets interrupted, e.g. by pressing Ctrl+C, you likely will need to [reset the cluster](#-reset) before trying again

1. Install Talos:

    ```sh
    task bootstrap:talos
    ```

2. Push your changes to git:

    ```sh
    git add -A
    git commit -m "chore: add talhelper encrypted secret :lock:"
    git push
    ```

3. Install cilium, coredns, spegel, argo and sync the cluster to the repository state:

    ```sh
    task bootstrap:apps CLUSTER_NAME=talos
    ```

4. Watch the rollout of your cluster happen:

    ```sh
    kubectl get pods --all-namespaces --watch
    ```

## 📣 Post installation

### ✅ Verifications

1. Check the status of Cilium:

    ```sh
    cilium status
    ```

2. Check the status of Argo and if the Argo resources are up-to-date and in a ready state:

   📍 _Run `task reconcile` to force Argo to sync your Git repository state_

    ```sh
    argocd login argo.${cloudflare_domain} --username admin --password ${argo_password} --insecure
    argocd cluster list
    argocd repo list --output wide
    argocd app list -A --output wide
    ```

3. Check TCP connectivity to both the internal and external gateways:

   📍 _The variables are only placeholders, replace them with your actual values_

    ```sh
    nmap -Pn -n -p 443 ${cluster_gateway_addr} ${cloudflare_gateway_addr} -vv
    ```

4. Check you can resolve DNS for `echo`, this should resolve to `${cloudflare_gateway_addr}`:

   📍 _The variables are only placeholders, replace them with your actual values_

    ```sh
    dig @${cluster_dns_gateway_addr} echo.${cloudflare_domain}
    ```

5. Check the status of your wildcard `Certificate`:

    ```sh
    kubectl -n cert-manager describe certificates
    ```

### 🌐 Public DNS

> [!TIP]
> Use the `external` gateway on `HTTPRoutes` to make applications public to the internet.

The `external-dns` application created in the `network` namespace will handle creating public DNS records. By default, `echo` and the `argo` are the only subdomains reachable from the public internet. In order to make additional applications public you must **set the correct gateway** like in the HelmRelease for `echo`.

### 🏠 Home DNS

> [!TIP]
> Use the `internal` gateway on `HTTPRoutes` to make applications private to your network. If you're having trouble with internal DNS resolution check out [this](https://github.com/onedr0p/cluster-template/discussions/719) GitHub discussion.

`k8s_gateway` will provide DNS resolution to external Kubernetes resources (i.e. points of entry to the cluster) from any device that uses your home DNS server. For this to work, your home DNS server must be configured to forward DNS queries for `${cloudflare_domain}` to `${cluster_dns_gateway_addr}` instead of the upstream DNS server(s) it normally uses. This is a form of **split DNS** (aka split-horizon DNS / conditional forwarding).

_... Nothing working? That is expected, this is DNS after all!_

### 🪝 Github Webhook

By default Argo will periodically check your git repository for changes. In-order to have Argo reconcile on `git push` you must configure Github to send `push` events to Argo.

1. Piece together the full URL with the webhook path appended:

    ```text
    https://argo.${cloudflare_domain}/api/webhook
    ```

2. Navigate to the settings of your repository on Github, under "Settings/Webhooks" press the "Add webhook" button. Fill in the webhook URL and your token from the ArgoCD admin password (obtained from the bootstrap process), Content type: `application/json`, Events: Choose Just the push event, and save.

## 💥 Reset

> [!CAUTION]
> **Resetting** the cluster **multiple times in a short period of time** could lead to being **rate limited by DockerHub or Let's Encrypt**.

There might be a situation where you want to destroy your Kubernetes cluster. The following command will reset your nodes back to maintenance mode.

```sh
task talos:reset
```

## 🛠️ Talos and Kubernetes Maintenance

### ⚙️ Updating Talos node configuration

> [!TIP]
> Ensure you have updated `talconfig.yaml` and any patches with your updated configuration. In some cases you **not only need to apply the configuration but also upgrade talos** to apply new configuration.

```sh
# (Re)generate the Talos config
task talos:generate-config
# Apply the config to the node
task talos:apply-node IP=? MODE=?
# e.g. task talos:apply-node IP=10.10.10.10 MODE=auto
```

### ⬆️ Updating Talos and Kubernetes versions

> [!TIP]
> Ensure the `talosVersion` and `kubernetesVersion` in `talenv.yaml` are up-to-date with the version you wish to upgrade to.

```sh
# Upgrade node to a newer Talos version
task talos:upgrade-node IP=?
# e.g. task talos:upgrade-node IP=10.10.10.10
```

```sh
# Upgrade cluster to a newer Kubernetes version
task talos:upgrade-k8s
# e.g. task talos:upgrade-k8s
```

## 🔧 Troubleshooting

### Common Issues

1. **Talos nodes not responding**:

   ```sh
   # Check if nodes are reachable
   nmap -Pn -n -p 50000 <node-ip>

   # Check Talos config
   talosctl config info
   ```

2. **Bootstrap fails**:

   ```sh
   # Check cluster status
   talosctl get nodes

   # Check bootstrap status
   talosctl bootstrap --nodes <control-plane-ip>
   ```

3. **ArgoCD not syncing**:

   ```sh
   # Force reconciliation
   task reconcile

   # Check ArgoCD logs
   kubectl logs -n argo-system deployment/argocd-server
   ```

4. **Certificate issues**:

   ```sh
   # Check certificate status
   kubectl get certificates -A

   # Check cert-manager logs
   kubectl logs -n cert-manager deployment/cert-manager
   ```

### Getting Help

- Check the [Talos documentation](https://www.talos.dev/)
- Review the [ArgoCD documentation](https://argo-cd.readthedocs.io/)
- Check cluster logs: `kubectl logs -n <namespace> <pod-name>`
