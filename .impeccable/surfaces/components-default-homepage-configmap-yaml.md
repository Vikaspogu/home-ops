---
version: 1
slug: "components-default-homepage-configmap-yaml"
primary_target: "components/default/homepage/configmap.yaml"
related_targets: ["components/default/homepage/values.yaml"]
---

# Homepage directory

Mode: Operate. The homelab owner launches application URLs and checks status. The user approved O1, a dark, quiet, crisp directory with all sections on one page.

Approved composition: `.impeccable/mocks/directory.png`. The later user request selects the indigo palette, blue-gray surfaces, amber focus, and Figtree typography. Preserve existing service URLs, secrets, bookmarks, widget integrations, and HTTPRoute discovery. Keep group names because discovery annotations depend on Ingress. Use Homepage v2.7.0 native affordances, no custom JavaScript or live-cluster access.

Direction contract:
- THESIS: A quiet directory keeps applications and real service status together.
- OWN-WORLD: Indigo surfaces, Figtree type, fine borders, and amber keyboard focus.
- STORY: Check infrastructure, scan application names, then open the destination.
- FIRST VIEWPORT: Compact identity and weather, full-width search, status strip, then service groups.
- FORM: Approved O1 directory, stacked full-width groups, seed 9e964f1f.

Implementation inventory:
- Background, separators, typography, responsive groups: CSS and native Homepage layout settings.
- Search: existing DuckDuckGo search, plus native type-to-search Quick Launch. Do not imitate the mockup's search label or keyboard shortcut if unsupported.
- Metrics and status: existing native widget integrations. No static Online labels, invented metrics, or extra monitoring integrations from the illustration.
- Icons and links: existing service definitions and Kubernetes discovery.
- Weather and date: existing native widgets, not the illustrative preview values.
- Bookmarks: existing targets, not generated image text.

Verification uses a temporary local Homepage container with sanitized configuration, discovered URL fixtures, and null API responses for widget loading states. It does not verify live service health or cluster connectivity.

Completed checks: Helm-enabled Kustomize render, embedded YAML parsing, unchanged service links/widgets/secrets/discovery, custom CSS mount, keyboard Quick Launch, focus styling, collapse controls, and new-tab links. Browser checks passed at 1440px, 768px, and 390px without horizontal overflow or weather overlap. Simulated API errors remain visible and expandable. An independent finish review found no material fixes. Figtree loaded at regular and semibold weights. Text and focus colors pass contrast checks. The temporary browser and container were closed after verification.

The user selected indigo with Figtree. Current reference screenshots are `.impeccable/mocks/indigo-figtree-desktop.png` and `.impeccable/mocks/indigo-figtree-mobile.png`. Figtree is requested through Google Fonts, with system fonts as fallback.

Pinned-version compatibility evidence:
- [v2.7.0 index.jsx](https://github.com/gethomepage/homepage/blob/v2.7.0/src/pages/index.jsx#L43) places resources and unifi_console directly under widgets-wrap, while search, datetime, and weather are inside information-widgets-right. Status strip styling intentionally selects the direct children. Date and weather remain unboxed.
- [v2.7.0 container_form.jsx](https://github.com/gethomepage/homepage/blob/v2.7.0/src/components/widgets/widget/container_form.jsx#L5) gives search information-widget-form rather than widget-container, so the status-strip selector does not double-box search.
- [v2.7.0 item.jsx](https://github.com/gethomepage/homepage/blob/v2.7.0/src/components/services/item.jsx#L23) supports cardStyle: hairline. [quicklaunch.jsx](https://github.com/gethomepage/homepage/blob/v2.7.0/src/components/quicklaunch.jsx#L123) supports mobileButtonPosition. [index.jsx](https://github.com/gethomepage/homepage/blob/v2.7.0/src/pages/index.jsx#L379) supports the page description. The unused layout sort option was removed.

Maintenance limits: CSS depends on this pinned version's DOM and requires a browser check when upgrading Homepage. Figtree uses Google Fonts and falls back to the system stack when unavailable. Deployment and live-service verification remain outside this change.
