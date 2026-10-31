---
version: 1
slug: "components-default-homepage-configmap-yaml"
primary_target: "components/default/homepage/configmap.yaml"
related_targets: ["components/default/homepage/values.yaml"]
---

# Homepage control surface

Mode: Operate. The homelab owner launches URLs and checks service status. The latest user-supplied home-control dashboard screenshot supersedes the earlier O1 composition and palette. Preserve Figtree and use near-black panels, rounded corners, inset icon tiles, compact status labels, and three desktop columns. The private reference image stays outside the repository.

Direction contract:
- THESIS: A quiet control surface keeps applications and real service status together.
- OWN-WORLD: Near-black surfaces, rounded cards, inset icon tiles, Figtree, and cyan keyboard focus.
- STORY: Find an application, check its status, then open the destination.
- FIRST VIEWPORT: Identity, weather, search, and status above infrastructure, applications, and media columns.
- FORM: Explicit user reference overrides the original O1 seed 9e964f1f. Use Homepage native links and widgets, not invented home-control features.

Implementation: three desktop columns at 1280px and above, with a wider two-column application directory in the center. Monitoring and media widgets occupy the side columns. On smaller screens, application links come first and groups stack vertically. Existing links, bookmarks, widget credentials, and error states remain intact.

Discovery corrections: disable Homepage discovery for Syncthing without removing its route. Replace the SRE icon's confirmed 404 URL with mdi-robot-outline. Correct route-to-pod mappings for Argo CD, Home Assistant Code, Garage API/UI, InfluxDB, Prometheus, Alertmanager, and Rook Ceph. Mark the NAS external because it has no Kubernetes pods. The user's screenshots identify these entries as Not found.

Evidence:
- [Homepage v2.7.0 status API](https://github.com/gethomepage/homepage/blob/v2.7.0/src/pages/api/kubernetes/status/%5B...service%5D.js#L21) defaults to app.kubernetes.io/name equal to the discovered app name. Zero matching pods produces Not found. Running is a pod-phase result, not an HTTP endpoint health check.
- [Resource discovery](https://github.com/gethomepage/homepage/blob/v2.7.0/src/utils/kubernetes/resource-helpers.js#L90) supports explicit app, external, and pod-selector annotations.
- Helm-enabled Kustomize renders reproduced missing matches before the annotation fixes and matched the backend workload labels/selectors afterward.
- [Rook v1.21.1 mgr controller](https://github.com/rook/rook/blob/v1.21.1/pkg/operator/ceph/cluster/mgr/mgr.go#L374) selects manager pods with app=rook-ceph-mgr.

Verification: local Homepage v2.7.0 runs with sanitized URL fixtures and mocked status/widget responses. Desktop, tablet, and mobile checks cover three-column placement, widths 1600/1280/900/390/320, native Running and Not found labels, Syncthing removal, SRE icon, external NAS behavior, Quick Launch, collapse controls, and keyboard focus. All passed without horizontal overflow or script errors. Text and focus colors pass contrast checks.

Screenshots: `.impeccable/mocks/control-surface-desktop.png` and `.impeccable/mocks/control-surface-mobile.png`. These use simulated data and do not establish live health. No durable kubeconfig was available for a live check. Figtree loads through Google Fonts with a system fallback. Custom CSS requires a browser check when upgrading the pinned Homepage version.
