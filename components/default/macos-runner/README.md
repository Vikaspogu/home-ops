# macos-runner

macOS guest (dockurr/macos, KVM in a privileged container) pinned to
`k8s-5-1u`, the only node with `devices.kubevirt.io/kvm` capacity. It exists
to run a Gitea `act_runner` natively on macOS so the t3code-orbit release
workflow can build the desktop DMG — something the Linux runners cannot do.

Legal note: Apple's EULA restricts macOS to Apple hardware. This is a
personal homelab choice; do not use for commercial distribution.

## First boot

Fully automated. On first start the image downloads the macOS 14 (Sonoma)
recovery from Apple and installs unattended onto the PVC (`macos-runner`,
200 Gi, mounted at `/storage`). Expect ~1 hour. Follow progress in the web
viewer:

```sh
kubectl port-forward svc/macos-runner 8006:8006
# open http://localhost:8006
```

## One-time bootstrap (manual, inside the guest)

1. Open the web viewer (above), wait for the macOS desktop.

2. In a guest terminal:

   ```sh
   # Xcode (needs an Apple ID for the download from developer.apple.com).
   # Only needed if we ever build iOS here; the unsigned desktop DMG build
   # works with just the Command Line Tools: xcode-select --install
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   brew install node@24

   # act_runner, registered with the host-execution label `macos`
   curl -LO https://dl.gitea.com/act_runner/latest/act_runner-darwin-amd64
   chmod +x act_runner-darwin-amd64
   ./act_runner-darwin-amd64 register --no-interactive \
     --instance https://gitea.a113.casa \
     --token <registration-token from https://gitea.a113.casa/admin/actions/runners> \
     --name macos-runner --labels "macos:host"
   ./act_runner-darwin-amd64 daemon   # or a launchd plist to keep it alive
   ```

   `macos:host` (no `:docker://...`) means jobs run directly on the guest OS.

## Workflow usage

Jobs in `.gitea/workflows/` select this runner with `runs-on: macos`. Build
unsigned DMGs with:

```sh
node scripts/build-desktop-artifact.ts --platform mac --target dmg --arch arm64
```

Unsigned DMGs trigger Gatekeeper on install (right-click → Open). Signing
needs an Apple Developer certificate added as Gitea secrets.

## Notes

- Guest CPU/RAM/disk come from `VERSION`/`CPU_CORES`/`RAM_SIZE`/`DISK_SIZE`
  env vars in values.yaml; the pod memory request must stay above the guest
  RAM or the OOM killer wins.
- Do not schedule anything else heavy on `k8s-5-1u` while a build runs.
