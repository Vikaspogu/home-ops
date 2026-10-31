---
name: Home Ops Homepage
description: A near-black homelab control surface with grouped app links and service
  status.
colors:
  home-bg: '#101216'
  home-surface: '#171a22'
  home-hover: '#202633'
  home-border: '#303642'
  home-text: '#edf0f6'
  home-muted: '#adb7c8'
  home-accent: '#39bdf1'
  home-icon: '#242b37'
typography:
  headline:
    fontFamily: '"Figtree", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: 1.75rem
    fontWeight: 650
    letterSpacing: -0.03em
  title:
    fontSize: 1.5rem
    fontWeight: 650
    letterSpacing: -0.025em
  body:
    fontSize: 0.875rem
    fontWeight: 600
  description:
    fontSize: 0.75rem
    fontWeight: 400
  metric:
    fontSize: 1.125rem
    fontWeight: 650
  label:
    fontSize: 0.6875rem
    fontWeight: 400
rounded:
  home-radius: 20px
  icon-radius: 14px
spacing:
  card-padding: 12px
  grid-gap: 12px
  widget-gap: 16px
  group-gap: 28px
  page-gutter: 32px
  mobile-gutter: 16px
components:
  service-card:
    backgroundColor: '{colors.home-surface}'
    textColor: '{colors.home-text}'
    rounded: '{rounded.home-radius}'
    padding: '{spacing.card-padding}'
  service-card-hover:
    backgroundColor: '{colors.home-hover}'
    textColor: '{colors.home-text}'
  icon-tile:
    backgroundColor: '{colors.home-icon}'
    rounded: '{rounded.icon-radius}'
    width: 48px
    height: 48px
  search-input:
    backgroundColor: '{colors.home-surface}'
    textColor: '{colors.home-text}'
    rounded: '{rounded.home-radius}'
---

# Design System: Home Ops Homepage

## Overview

**Creative North Star: "The Quiet Control Surface"**

This system covers Homepage only. The user supplied a home-control dashboard reference with a near-black canvas, rounded panels, inset icon tiles, compact status badges, and three parallel content columns. The implementation adapts that visual language to existing application links and native Homepage widgets.

Figtree remains the interface font. Actual widget states retain their native meanings and colors.

**Key Characteristics:**
- Near-black canvas and rounded panels.
- Three desktop columns with a wider application directory.
- Inset icon tiles, wrapping labels, and cyan keyboard focus.

## Colors

The near-black canvas (`home-bg`) and dark panels (`home-surface`) form the main layers. Hover surfaces (`home-hover`) and fine borders (`home-border`) define interactions. Primary text (`home-text`) is near-white, secondary text (`home-muted`) is a cool neutral, and cyan (`home-accent`) marks keyboard focus. Inset icon tiles use `home-icon`.

Native success, warning, and error colors remain visible alongside text labels. A decorative border must not imply a healthy service.

## Typography

Figtree loads through Google Fonts with swap display and a system-font fallback. The greeting remains the largest heading. Column headings use the title role, service names use the body role, and measurements use the metric role with tabular numerals. Names and labels wrap rather than disappearing behind ellipses.

## Layout

Content is limited to 1600px with 32px desktop gutters. Identity, date, weather, full-width search, and status widgets sit above the content.

At 1280px and wider, three columns place Observability on the left, Ingress in a wider center column, and Media on the right. The column ratio is 1:1.7:1. Infrastructure and media widgets stack vertically. The application directory uses two columns. Git bookmarks span the width below these groups.

Below that breakpoint, groups stack vertically using native Homepage grids, with the application directory first so launch links remain easy to reach. At 767px and narrower, gutters shrink to 16px and service cards become a single column. Date and weather each use half of the header width. All links and service widgets remain available.

## Elevation & Depth

Panels use a fine border and tonal separation without shadows. Hover changes background and border color over 160ms with ease-out easing. Reduced-motion preferences disable animations and transitions inside the page.

## Shapes

Panels and search share the main rounded token. Service icons sit in inset tiles with rounded corners (14px), a fixed size (48px), and artwork bounded to 28px. Native Kubernetes status badges have gently rounded corners (6px).

## Components

### Application and Status Cards

Cards use the service-card tokens and a title row with a minimum height (60px). An icon tile precedes a wrapping service name and secondary description. Native Kubernetes status stays beside the title. Widget measurements sit below a fine divider with larger values and quieter labels.

### Group Buttons

Native group heading buttons keep their collapse behavior, a minimum height (44px), and title typography.

### Search and Keyboard Focus

The native search input remains full-width with a minimum height (48px). Native type-to-search Quick Launch and its mobile button remain available. Links, buttons, inputs, and error summaries receive a cyan focus-visible outline (2px) with an inward offset (-2px).

### Error and Loading States

Native loading placeholders, status text, highlights, and expandable API errors remain intact. Error summary text uses the primary text color. No static healthy labels replace real status. Native Running and Not found labels describe Kubernetes pod status, not HTTP endpoint health. External services such as NAS do not show a Kubernetes badge. Preview data is mocked and does not establish live health.

## Do's and Don'ts

### Do:
- **Do** keep the three desktop columns distinct while preserving all content on narrower screens.
- **Do** retain native widget loading, status, and expandable error states.
- **Do** keep Figtree, inset icon tiles, wrapping names, and cyan keyboard focus consistent.

### Don't:
- **Don't** invent service health, camera feeds, or home-control actions to imitate the reference.
- **Don't** remove status text in favor of color alone.
