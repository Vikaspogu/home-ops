# macos-runner

macOS guest (docker-osx, KVM in a privileged container) pinned to `k8s-5-1u`,
the only node with `devices.kubevirt.io/kvm` capacity. It exists to run a
Gitea `act_runner` natively on macOS so the t3code-orbit release workflow can
build the desktop DMG (and later iOS) — things the Linux runners cannot do.

Legal note: Apple's EULA restricts macOS to Apple hardware. This is a personal
homelab choice; do not use for commercial distribution.

## First boot

The init container seeds the PVC (`macos-runner`, 200 Gi) with the prebuilt
OpenCore firmware and installed macOS disk from the image. First start takes
a long time (tens of GB copied to Ceph). Later restarts skip the copy.

## One-time bootstrap (manual, inside the guest)

1. Watch the console / attach VNC:

   ```sh
   kubectl port-forward svc/macos-runner 5900:5900
   # open vnc://localhost:5900
   ```

2. Finish macOS setup, then in a guest terminal:

   ```sh
   # Xcode (needs an Apple ID for the xip download from developer.apple.com)
   brew install xcodes && xcodes install --latest
   sudo xcodebuild -license accept

   # Node 24 (repo engines: ^24.13.1)
   brew install node@24

   # act_runner, registered with the host-execution label `macos`
   curl -LO https://gitea.a113.casa/api/packages/vpogu/generic/act_runner/latest/act_runner-darwin-amd64 2>/dev/null \
     || curl -LO https://dl.gitea.com/act_runner/latest/act_runner-darwin-amd64
   chmod +x act_runner-darwin-amd64
   ./act_runner-darwin-amd64 register --no-interactive \
     --instance https://gitea.a113.casa \
     --token <registration-token from https://gitea.a113.casa/admin/actions/runners> \
     --name macos-runner --labels "macos:host"
   ./act_runner-darwin-amd64 daemon   # or a launchd plist to keep it alive
   ```

   `macos:host` (no `:docker://...`) means jobs run directly on the guest OS.

3. Enable SSH in macOS (System Settings → Sharing → Remote Login) if shell
   access is wanted; the pod forwards it on service port 10022.

## Workflow usage

Jobs in `.gitea/workflows/` select this runner with `runs-on: macos`. Build
unsigned DMGs with:

```sh
node scripts/build-desktop-artifact.ts --platform mac --target dmg --arch arm64
```

Unsigned DMGs trigger Gatekeeper on install (right-click → Open). Signing
needs an Apple Developer certificate added as Gitea secrets.

## Notes

- `GENERATE_UNIQUE=true` gives the guest a unique serial; iServices/iCloud
  sign-in is optional and not required for builds.
- CPU/RAM are qemu args in `EXTRA` (8 vCPU, 16 GiB); pod requests must stay
  above the guest RAM or the OOM killer wins.
- Do not schedule anything else heavy on `k8s-5-1u` while a build runs.
