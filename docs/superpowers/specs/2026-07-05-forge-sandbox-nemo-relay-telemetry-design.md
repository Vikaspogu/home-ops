# Forge Sandbox NeMo Relay Telemetry Design

## Goal

Expose Forge-created OpenShell sandbox LLM and tool activity in Tempo/Grafana through NeMo Relay and the existing Alloy OTLP receiver. Preserve Forge's control-plane telemetry and avoid modifying the OpenShell gateway's supervisor-managed sandbox launch sequence.

## Scope

This design covers only sandboxes created by Forge agent nodes.

It does not add telemetry to arbitrary OpenShell clients, the OpenShell gateway, or the OpenShell supervisor. It does not add a Relay Service, sidecar, admission mutation, HTTPRoute, collector, or credential.

## Existing Contract

Forge already has two telemetry settings in `components/ai/forge/values.yaml`:

- `FORGE_OTEL_ENDPOINT`: Forge control-plane OTLP/HTTP endpoint.
- `FORGE_OTEL_SANDBOX_ENDPOINT`: bare Alloy host and port for the sandbox Relay path.

The pinned Forge implementation consumes the first setting for `service.name=forge-orchestrator`. It consumes the second when creating an OpenShell agent sandbox: it builds an OpenInference NeMo Relay configuration, starts Relay on sandbox loopback, and directs the coding agent through that local Relay gateway.

The sandbox Relay identity is `service.name=forge-sandbox-agent`. Its resource attributes include Forge task, node, attempt, and trace identifiers. Relay does not propagate `TRACEPARENT` in this integration, so Forge-to-sandbox correlation is attribute-based rather than a single Tempo trace tree.

Alloy already receives OTLP/HTTP on port 4318 and exports traces to Tempo. Grafana already has the Tempo datasource.

## Decision

Use one Relay boundary per Forge-created sandbox. Forge owns orchestration telemetry; the sandbox Relay owns coding-agent LLM and tool telemetry.

The custom sandbox image is the implementation boundary. It must contain the NeMo Relay runtime required by Forge. No OpenShell Helm value, Pod mutation, sidecar, or command wrapper is introduced.

## Data Flow

```text
Forge agent node
  -> creates OpenShell sandbox with non-secret Forge correlation attributes
  -> starts loopback NeMo Relay inside sandbox
  -> coding agent sends provider traffic through Relay
  -> Relay exports OpenInference OTLP/HTTP to Alloy :4318
  -> Alloy batches and forwards OTLP/gRPC to Tempo :4317
  -> Grafana queries Tempo
```

## Required Invariants

- The sandbox Relay is bound only to loopback within the sandbox.
- The Relay exporter points to `http://alloy.observability.svc.cluster.local:4318/v1/traces`.
- The sandbox image remains immutable and digest-pinned in Forge configuration.
- No provider credential, telemetry credential, or secret is added to sandbox configuration.
- OpenShell continues to own the sandbox supervisor command, init containers, volumes, and security context.
- Sandbox traces use `service.name=forge-sandbox-agent`; control-plane traces remain `service.name=forge-orchestrator`.

## Current Gap Analysis

Verified against repo state on 2026-07-08. The downstream half of the pipeline (Alloy -> Tempo -> Grafana) is established: `components/ai/hermes-agent/` exports OpenInference OTLP/HTTP to the same Alloy `:4318/v1/traces` receiver and passes `scripts/test-hermes-nemo-relay-rendered-manifest.sh`. The Grafana ConfigMap and its rendered-manifest contract are delivered in Git: `components/observability/grafana/dashboards/forge.yaml` retains the separate `forge-orchestrator` trace panel and now contains the `forge-sandbox-agent` panel; `scripts/test-forge-dashboard-rendered-manifest.sh` renders the Grafana component and verifies the dashboard contract. This does not establish GitOps reconciliation, production sandbox Relay configuration, or live `forge-sandbox-agent` trace presence. Remaining gaps are those separately gated deployment and sandbox-side producer checks.

1. Relay OpenInference exporter section (blocking, not repo-visible). Relay emits nothing unless `[components.config.openinference]` has `enabled = true`. For the Forge sandbox this config is built at runtime by the Forge runner inside the digest-pinned sandbox image, so it cannot be set from this repo. Contract Forge must satisfy: `enabled=true`, `transport="http_binary"`, full-URL `endpoint`, `service_name="forge-sandbox-agent"`.
2. Endpoint shape contract (unverified, Forge-image behavior). The two Forge settings deliberately differ: `FORGE_OTEL_ENDPOINT` carries scheme but no path (`http://alloy...:4318`), and `FORGE_OTEL_SANDBOX_ENDPOINT` is a bare `host:port` (`alloy.observability.svc.cluster.local:4318`). The Relay `endpoint` field, by contrast, requires a full URL with the `/v1/traces` path (as hermes-agent uses). This shape difference strongly implies the Forge runner constructs the full exporter URL from the bare endpoint itself. That construction is not visible in this repo and is not verified here; it is the endpoint contract Forge must satisfy, and the first thing to confirm in the sandbox image if traces do not appear.
3. Sandbox egress allowlist. Kubernetes/Cilium layer is already open: no NetworkPolicy or CiliumNetworkPolicy scopes namespace `openshell-sandboxes`, and no default-deny egress exists, so pod egress to `alloy.observability:4318` is not blocked. The OpenShell OPA proxy layer is handled by Forge's `_build_network_policy`, which injects the `forge_otel` rule (host/port + binary `/usr/local/bin/nemo-relay`) only when `otel_sandbox_endpoint` is set. Contract dependency: the Relay binary exists at `/usr/local/bin/nemo-relay` in the sandbox image.
4. Grafana sandbox view (delivered Git configuration; reconciliation and live-query validation remain gated). `components/observability/grafana/dashboards/forge.yaml` retains its distinct `forge-orchestrator` trace panel and contains the distinct Tempo trace panel `Recent sandbox agent traces`, which queries `{ resource.service.name = "forge-sandbox-agent" }`. `scripts/test-forge-dashboard-rendered-manifest.sh` renders the Grafana component and asserts the sandbox panel's single service identity, Tempo datasource, and exact TraceQL query. It does not prove GitOps has reconciled the ConfigMap or that Tempo contains sandbox traces.
5. Tempo metrics-generator is disabled (`components/observability/tempo/values.yaml`, `metricsGenerator.enabled: false`). Raw traces into Grafana do not need it; RED-style (rate/error/duration) aggregate panels for the sandbox service do.

Out of scope for this trace pipeline: OpenShell OCSF sandbox audit logs are files inside the sandbox (`/var/log/openshell-ocsf.*.log`), while Alloy tails container stdout only (`/var/log/pods/*`). Those audit logs are a separate stream, not collected today.

## Gated Rollout

1. After GitOps reconciliation, open the already-provisioned Forge dashboard and query/validate its `Recent sandbox agent traces` Tempo panel:

   ```traceql
   { resource.service.name = "forge-sandbox-agent" }
   ```

2. If traces exist, validate that the sandbox panel returns `forge-sandbox-agent` traces while the retained `forge-orchestrator` panel remains separate. Do not change runtime configuration.

3. If no traces exist, execute one known Forge agent-node workflow, then rerun the query within the trace-retention window.

4. If the workflow does not emit Relay traces, inspect the selected sandbox image's Relay executable and supported configuration contract.

5. Only when inspection proves Relay is absent or incompatible, rebuild the sandbox image with a compatible NeMo Relay runtime, publish a new immutable digest, and update only Forge's `FORGE_SANDBOX_IMAGE` reference.


## Verification

A successful integration must prove all of the following:

- A Forge agent-node workflow creates a sandbox.
- The sandbox image contains the Relay executable expected by Forge.
- Tempo returns a `forge-sandbox-agent` trace.
- The trace has Forge task/node/attempt correlation attributes.
- The trace contains OpenInference LLM or tool spans.
- Existing `forge-orchestrator` control-plane traces continue to appear separately.
- The rendered Forge dashboard provides separate `forge-orchestrator` and `forge-sandbox-agent` Tempo trace panels.
- The OpenShell gateway and sandbox supervisor remain healthy.

## Failure Behavior

Telemetry must not require a public endpoint or a separate in-cluster Relay Service. A telemetry export failure must not expand sandbox network permissions or require credentials. If Relay cannot be started because the sandbox image is incompatible, treat that as an image-contract failure and repair the image rather than modifying the OpenShell chart or bypassing the supervisor.

## Sources

- Forge component: `components/ai/forge/values.yaml`
- OpenShell component and vendored chart: `components/ai/openshell/`
- Alloy OTLP receiver/exporter: `components/observability/alloy/values.yaml`
- Tempo retention and receiver: `components/observability/tempo/values.yaml`
- Grafana Tempo datasource: `components/observability/grafana/values.yaml`
- Pinned Forge Relay implementation: https://gitea.a113.casa/vpogu/forge/src/commit/e181d19b1086ca2ac9af4baec6317ef61d3660c0/src/forge/runners/openshell.py
- NVIDIA OpenShell sandbox model: https://docs.nvidia.com/openshell/latest/about/how-it-works
