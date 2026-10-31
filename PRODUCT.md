# Homepage

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The homelab owner uses Homepage as a daily launcher to access application URLs and check service status.

## Product Purpose

Make applications easy to find and open while keeping useful homelab status visible.

## Operating Context

Homepage v2.7.0 runs on Kubernetes. ArgoCD manages its ConfigMap and Helm values under `components/default/homepage/`. HTTPRoute annotations supply automatically discovered applications.

## Capabilities and Constraints

Preserve existing application URLs, widget integrations, secret placeholders, and Kubernetes discovery. Use Homepage configuration and supported custom CSS rather than a replacement application. Keep keyboard navigation, responsive layouts, and real error states available. Deployment is outside the authorized local redesign.

## Brand Commitments

The user requested a unique, clean, fresh design and confirmed a dark, quiet, crisp viewing style. The user requested Figtree typography and later supplied a home-control dashboard reference for its near-black panels, icon tiles, and three-column layout.

## Evidence on Hand

`components/default/homepage/configmap.yaml` defines bookmarks, service widgets, settings, and information widgets. `components/default/homepage/values.yaml` defines config mounts and the pinned image. Live service status is unavailable during design and must not be invented.
