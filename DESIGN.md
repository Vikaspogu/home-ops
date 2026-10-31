---
name: Home Ops Homepage
description: Quiet Precision / Dark Obsidian for application launch and operational status.
colors:
  home-bg: '#0b0e14'
  home-hover: '#1c2330'
  home-border: 'rgba(255, 255, 255, 0.06)'
  home-text: '#f8fafc'
  home-muted: '#94a3b8'
  home-accent: '#38bdf8'
  home-icon: 'rgba(148, 163, 184, 0.10)'
  secure: '#34d399'
  warning: '#fbbf24'
  alert: '#fb7185'
surfaces:
  home-surface: 'linear-gradient(180deg, rgba(24, 29, 40, 0.88), rgba(16, 20, 28, 0.92))'
typography:
  headline:
    fontFamily: '"Figtree", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: 1.625rem
    fontWeight: 800
    lineHeight: 1.1
    letterSpacing: -0.03em
    fontFeature: '"cv02", "cv03", "cv04", "cv11"'
  title:
    fontSize: 0.875rem
    fontWeight: 700
    letterSpacing: -0.015em
  description:
    fontSize: 0.75rem
    fontWeight: 500
  metric:
    fontFamily: '"JetBrains Mono", ui-monospace, monospace'
    fontSize: 1.125rem
    fontWeight: 600
  kicker:
    fontSize: 0.6875rem
    fontWeight: 700
    letterSpacing: 0.10em
  status:
    fontFamily: '"JetBrains Mono", ui-monospace, monospace'
    fontSize: 0.625rem
    fontWeight: 600
rounded:
  home-radius: 18px
  icon-radius: 12px
  dock-radius: 22px
  pill-radius: 999px
spacing:
  card-padding: 12px 14px
  grid-gap: 10px
  group-gap: 20px
  page-gutter: 32px
  mobile-gutter: 16px
components:
  service-card:
    textColor: '{colors.home-text}'
    rounded: '{rounded.home-radius}'
    padding: '{spacing.card-padding}'
  service-card-hover:
    backgroundColor: '{colors.home-hover}'
    textColor: '{colors.home-text}'
  icon-tile:
    backgroundColor: '{colors.home-icon}'
    rounded: '{rounded.icon-radius}'
    width: 38px
    height: 38px
  search-input:
    textColor: '{colors.home-text}'
    rounded: '{rounded.home-radius}'
    height: 48px
---

# Design System: Home Ops Homepage

## Overview

**Creative North Star: "Quiet Precision / Dark Obsidian"**

A dark operational launcher pairs compact application tiles with real Homepage telemetry. Tactile gradients and inset highlights give each target a clear boundary. Semantic color reflects reported state, while idle services remain quiet.

**Key Characteristics:**
- Obsidian canvas, fine borders, and inset surface highlights.
- Figtree labels with steady JetBrains Mono telemetry.
- Two-up mobile launch tiles and three balanced desktop sections.

## Colors

The canvas uses `home-bg`, primary labels use `home-text`, and secondary labels use `home-muted`. Cyan `home-accent` provides visible keyboard focus. Neutral icon badges use `home-icon`.

**The Reported State Rule.** Emerald identifies native Kubernetes Running status. Rose identifies Down, Not found, Partial, or Error. These states tint the card, border, and icon badge. Native widget good, warn, and danger highlights use emerald, amber, and rose respectively. Pod state does not establish URL health.

## Typography

Figtree loads weights 400 through 800 with the configured character variants. JetBrains Mono loads weights 500 and 600 for date, weather, resource readings, network readings, widget values, and Kubernetes status. These regions use tabular numerals.

The page title uses the headline role. Section headings are compact uppercase kickers, card names use the title role, and secondary descriptions use the description role. Card names stay on one line with ellipsis. Widget labels can wrap; measurements remain legible within their card.

## Layout

Content is limited to 1600px with desktop gutters from `page-gutter`. Identity, date, weather, full-width search, and native resource widgets precede the service groups.

At 1144px and wider, three equal columns have a minimum width (340px) and group gaps from `group-gap`. Observability sits left, Ingress center, and Media right. Each section stacks its cards. Git bookmarks span the width below.

Below that breakpoint, groups stack with Ingress first. Launch tiles use two columns from 360px through 1143px, then one column below 360px. At 767px and narrower, gutters use `mobile-gutter` and date and weather each take half the header width. Below 640px, the native Quick Launch button becomes a centered glass dock. Bottom padding reserves 110px plus the safe-area inset.

## Elevation & Depth

Idle panels use a vertical gradient from translucent dark slate to deeper carbon with a fine border. A subtle top-edge inset highlight supplies depth. Hover brightens cards over 160ms. Neutral cards also use `home-hover` and a brighter border, while state cards retain their semantic gradients and borders. The mobile dock adds translucent glass, blur (20px), and a soft shadow. Reduced-motion preferences disable page animations and transitions.

## Shapes

Cards and search use `home-radius`. Icon badges use `icon-radius` with artwork bounded to 24px. Kubernetes badges are pills. The resource summary and mobile dock use `dock-radius`.

## Components

### Service Tiles

A compact title row pairs a fixed icon badge with the service name and secondary description. Its minimum inner height (42px) plus vertical card padding produces a minimum tile height (66px) before borders. Widget cards grow to fit their measurements. Where Kubernetes status is present, its pill replaces the description beneath the title. The status control retains its native interaction.

### Section Buttons and Search

Native collapse buttons keep a minimum height (44px). The full-width search field keeps a minimum height (48px). Links, buttons, inputs, and error summaries receive a cyan focus-visible outline (2px) with an inward offset (-2px).

### Mobile Quick Launch

The native Quick Launch trigger becomes a centered glass button with a visible label, width (180px), and height (60px). It retains the existing search dialog and keyboard behavior.

### Telemetry and Errors

Widget measurements use the metric role above quieter labels. Native loading placeholders, reported status, and expandable API errors remain available. External services have no Kubernetes badge. Missing data remains visible for diagnosis rather than being hidden or replaced by a healthy label. Static layout order does not imply live activity sorting.

## Do's and Don'ts

### Do:
- **Do** use real reported state for semantic tinting and retain its text label.
- **Do** keep numeric telemetry monospace and tabular.
- **Do** preserve native links, widget content, errors, and keyboard access.

### Don't:
- **Don't** invent presence, device controls, or sensor values.
- **Don't** hide unavailable services or claim URL health from pod state.
- **Don't** let the mobile dock cover the final content row.

Enhanced state surfaces use CSS :has(), supported by Chromium 105+, Firefox 121+, and Safari 15.4+. Older browsers retain native labels and base card styling. The Quick Launch label comes from CSS generated content and was verified in the Chromium accessibility tree. Its selector follows the pinned Homepage version.
