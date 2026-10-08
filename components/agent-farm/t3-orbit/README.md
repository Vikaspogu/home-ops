# T3 Orbit test route

`https://t3-orbit.a113.casa` uses the internal Envoy gateway. Orbit's own
pairing and session authentication protect the app; the route does not use
Authentik. The Service selects only Agent Farm workspace `acac5578e380aa52`.
The VM must serve T3 on `0.0.0.0:3773`.

The guest uses KubeVirt masquerade networking. Its VM interface must include
TCP port 3773 before the Service can reach it. Add the port to the VM template
and restart the test VM once; adding only this HTTPRoute will leave a 503
backend. The T3 system unit installed on the guest is enabled and starts on
boot. Verify the VM ID and current interface ports before patching:

```sh
kubectl -n agent-farm get vm acac5578e380aa52 \
  -o jsonpath='{.spec.template.spec.domain.devices.interfaces[0].ports}'
```

If port 3773 is absent, append it to the interface's `ports` list. A workspace
image upgrade recreates the VM from Agent Farm's standard template and removes
this test-specific port; reapply it after such an upgrade. The route, DNS,
Service, and network policy remain managed by this component.
