---
version: 1
slug: "components-default-homepage-configmap-yaml"
primary_target: "components/default/homepage/configmap.yaml"
related_targets: ["components/default/homepage/values.yaml"]
---

# Homepage Quiet Precision

Mode: Operate. The owner opens application URLs and checks homelab status. The explicit Quiet Precision / Dark Obsidian prompt supersedes the earlier reference rendition. Preserve native Homepage discovery, links, widgets, credentials, errors, search, collapse, and keyboard navigation.

Direction: obsidian gradient surfaces with inset highlights, compact Figtree labels, JetBrains Mono numeric telemetry, small section kickers, and inset icon tiles. Pod running states tint emerald. Missing, partial, down, and API error states tint rose. Native widget highlights retain good/warn/danger meanings. No invented climate, security, power, or presence data.

Composition: three equal desktop section columns with a 340px minimum at 1144px. Application launchers come first on smaller screens with two tiles per row from 360px. At 320px, use one column. Tile titles ellipsize visually while their full native text remains accessible. Monitoring widgets keep room for their readings. The native mobile Quick Launch button becomes a 60px glass dock with 110px plus safe-area clearance below the page.

Platform adaptations: unavailable applications stay visible for recovery, and source order stays stable for keyboard users. Homepage has no HA entity model or semantic device controls. Do not fabricate presence pills, three-button action rows, device-state sorting, or counts. Unknown pod state stays neutral. No custom JavaScript or replacement frontend is introduced.

Verification: local Homepage v2.7.0 with sanitized fixtures and mocked pod/widget responses. Checks passed at 1600, 1144, 1139, 1124, 900, 430, 390, and 320px without horizontal overflow or page errors. Verified real status-derived tint selectors, telemetry font, and mobile Quick Launch search. ConfigMap rendering and embedded YAML pass. Live cluster health remains unverified.

Screenshots: `.impeccable/mocks/obsidian-desktop.png` and `.impeccable/mocks/obsidian-mobile.png`. Values and statuses are simulated. Fonts load via Google Fonts with local fallbacks. Recheck native selectors when upgrading the pinned Homepage version.

Review follow-up: a focused check reproduced scrollbar-edge overflow by reducing the content width by 17px. Raising the desktop breakpoint to 1144px cleared it. The native dock resolves as a button named Quick Launch in the Chromium accessibility tree. Native selectors and CSS :has() are intentional dependencies of the pinned Homepage surface, with native state labels retained as fallback.
