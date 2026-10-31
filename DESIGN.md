---
name: Home Ops Homepage
description: A dark, quiet, crisp application directory with service status.
colors:
  home-bg: "#111526"
  home-surface: "#1c2439"
  home-hover: "#27344d"
  home-border: "#3a4b69"
  home-text: "#edf1ff"
  home-muted: "#b2bfd7"
  home-accent: "#f1c787"
typography:
  headline:
    fontFamily: '"Figtree", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: "1.75rem"
    fontWeight: 650
    letterSpacing: "-0.03em"
  title:
    fontSize: "1.0625rem"
    fontWeight: 600
    letterSpacing: "-0.015em"
  body:
    fontSize: "0.875rem"
    fontWeight: 600
  description:
    fontSize: "0.75rem"
    fontWeight: 400
  metric:
    fontSize: "0.875rem"
    fontWeight: 500
  label:
    fontSize: "0.6875rem"
    fontWeight: 400
rounded:
  home-radius: "12px"
spacing:
  card-padding: "8px"
  grid-gap: "12px"
  widget-gap: "16px"
  group-gap: "28px"
  page-gutter: "32px"
  mobile-gutter: "16px"
components:
  service-card:
    backgroundColor: "{colors.home-surface}"
    textColor: "{colors.home-text}"
    rounded: "{rounded.home-radius}"
    padding: "{spacing.card-padding}"
  service-card-hover:
    backgroundColor: "{colors.home-hover}"
    textColor: "{colors.home-text}"
  search-input:
    backgroundColor: "{colors.home-surface}"
    textColor: "{colors.home-text}"
    rounded: "{rounded.home-radius}"
---

# Design System: Home Ops Homepage

## Overview

**Creative North Star: "The Quiet Directory"**

This system covers Homepage only, not the infrastructure repository. It records the approved O1 Directory implemented in `components/default/homepage/configmap.yaml`, running on Homepage v2.7.0 as pinned in `values.yaml`.

Indigo surfaces, Figtree typography, and fine borders support daily application launching and status checks. Native Homepage controls and widget states remain part of the interface.

**Key Characteristics:**
- Dark, quiet, crisp.
- Compact application cards with clear names and secondary descriptions.
- Amber keyboard focus and restrained surface changes on hover.

## Colors

### Primary

Amber (`home-accent`) marks keyboard focus on links, buttons, inputs, and expandable error summaries.

### Neutral

Deep indigo (`home-bg`) forms the page. Blue-gray (`home-surface`) contains search, status widgets, service cards, and bookmarks. Hover indigo (`home-hover`) and muted borders (`home-border`) distinguish interactive surfaces without bright fills. Near-white (`home-text`) identifies primary content, while pale blue-gray (`home-muted`) carries descriptions, labels, and placeholder text.

Native service icons and status/error colors retain their meaning. The custom neutral palette does not replace widget highlights.

## Typography

Figtree, loaded through Google Fonts with swap display and the system stack as fallback, applies throughout. The greeting is the largest text. Group titles are smaller and semibold. Service names use the body role, descriptions use the description role, and metric values use the metric role with tabular numerals.

Date text and bookmark names use a compact size (0.8125rem). Metric labels stay in normal case. Service names, metric values, and labels can wrap when space is tight.

## Layout

The content has a maximum width (1600px), with desktop page gutters and stacked full-width groups. Native row layouts request five Observability columns, four Ingress columns, four Media columns, and two Git columns. Homepage handles the service-grid column changes at narrower widths.

The information area uses a twelve-column grid. Greeting occupies six columns, date and weather three each. Search spans the full width, followed by two six-column status widgets. Group titles end in a fine horizontal divider.

At widths up to 767px, page gutters shrink to the mobile value, the greeting and status widgets span the full width, and date and weather each occupy six columns. Information spacing tightens to 12px and top/bottom spacing to 24px. Bookmark descriptions wrap beneath their names. Native Quick Launch keeps its mobile button at the bottom right.

## Elevation & Depth

The custom search, service cards, and bookmark surfaces use no box shadow. Tonal layers and thin borders provide separation. Cards change background and border color on hover, without added movement. These changes take 160ms with ease-out easing. Reduced-motion preferences disable animations and transitions inside the page.

## Shapes

Search, status containers, service cards, and bookmark links share the rounded token. Borders and internal widget separators are thin (1px). Service icons occupy a fixed width (40px), preserving alignment between names.

## Components

### Search

The existing DuckDuckGo search stays full-width with a minimum input height (48px), muted placeholder text, a surface fill, and a fine border. Keyboard focus uses the shared amber outline. Native type-to-search Quick Launch remains available.

### Service Cards and Bookmarks

Cards use the frontmatter service-card tokens. Service title rows have a minimum height (48px). Widget content sits below a fine divider, with wrapping metric blocks. Hover changes the surface and border to the hover and muted colors. Bookmark links share this treatment and have a minimum height (56px).

Service data, loading states, highlights, and expandable API errors come from native widgets. Error summary text uses the primary text color, and keyboard focus on its disclosure uses the shared outline. Preview placeholders do not establish live health or status.

### Group Buttons and Keyboard Focus

Native group buttons retain their collapse behavior, with a minimum height (36px), a gap (12px), and a trailing divider. All page links, buttons, inputs, and error summaries receive an amber focus-visible outline (2px) with an inward offset (-2px). No additional custom button variants are defined.

## Do's and Don'ts

### Do:
- **Do** retain native widget loading, highlight, and expandable error states.
- **Do** keep the shared amber focus treatment on keyboard controls.
- **Do** preserve compact names, secondary descriptions, and wrapping content on narrow screens.

### Don't:
- **Don't** replace real service status with static healthy labels.
- **Don't** introduce a replacement application or custom JavaScript for this Homepage system.
