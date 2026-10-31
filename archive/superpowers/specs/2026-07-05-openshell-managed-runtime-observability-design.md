# OpenShell Managed Runtime Observability Design

## Goal

Provide semantic OpenTelemetry traces for the OpenShell gateway and NeMo Relay/OpenInference traces for every participating OpenShell managed-agent sandbox. Export both directly to the existing Alloy OTLP/HTTP receiver, then Tempo and Grafana.

## Scope

The design covers a standard managed agent runtime used by every participating OpenShell client. Forge is a participating client and must migrate to this contract in one clean cutover.

The design does not intercept arbitrary workloads. It does not replace OpenShell supervisor-owned commands, init containers, volumes, mounts, or security contexts. It does not introduce a Relay Service, sidecar, admission mutation, HTTPRoute, or telemetry credential.

## Current State

OpenShell (gateway `0.0.77`, supervisor `0.0.72` in `components/ai/openshell/values.yaml`, vendored chart `oci://ghcr.io/nvidia/openshell` version `0.0.0-dev`) has structured logs, Prometheus metrics, and anonymous vendor telemetry, but no native OpenTelemetry, OTLP, OpenInference, or NeMo Relay gateway integration. A grep of the chart and values finds no OTEL/OTLP/tracing keys.

Repository values use gateway `0.0.77`; earlier drafts of this design referenced `0.0.76`. The upstream tracing patch and the vendored chart update must target the reconciled `0.0.77` release.

Forge currently implements a private per-sandbox Relay contract. It emits sandbox LLM/tool traces as `service.name=forge-sandbox-agent`. This confirms the Alloy, Tempo, Grafana, and sandbox Relay path works, but it is not a reusable OpenShell platform contract. Verified downstream: `components/ai/hermes-agent/` exports OpenInference OTLP/HTTP to Alloy `:4318/v1/traces` and is covered by `scripts/test-hermes-nemo-relay-rendered-manifest.sh`, so the Alloy -> Tempo -> Grafana half is proven end to end. What remains missing for managed-runtime traces is entirely upstream: the gateway emits no spans (no OTEL module) and there is no reusable per-sandbox OpenInference exporter contract yet.

The local OpenShell chart renders the gateway workload and gateway configuration. It does not provide a generic safe injection point for dynamically created sandbox Pods.

## Decision

Contribute optional gateway OpenTelemetry support upstream to OpenShell, then consume an upstream released gateway/chart version. Add a standard managed runtime contract enforced by the gateway for participating clients.

The gateway owns control-plane lifecycle tracing. The managed sandbox runtime owns agent, LLM, and tool tracing. Each sandbox has exactly one Relay owner.

## Gateway Tracing

The upstream gateway implementation must add an optional OpenTelemetry module that:

1. Exports OTLP/HTTP protobuf to Alloy when explicitly configured through standard OTEL environment variables.
2. Bridges the existing Rust `tracing` subscriber to OpenTelemetry.
3. Extracts W3C `traceparent` and `tracestate` plus allowlisted baggage at HTTP/gRPC ingress.
4. Emits nested semantic spans for sandbox create, delete, exec, readiness, failure, and supervisor connect/disconnect transitions.
5. Persists server-owned trace context keyed by canonical sandbox UUID so background lifecycle transitions remain correlated after the create RPC ends.

Gateway resource identity:

```text
service.name=openshell-gateway
service.version=<OpenShell release>
service.instance.id=<gateway instance>
```

Gateway lifecycle spans use `openinference.span.kind=TOOL`, not `LLM`. They include only canonical sandbox ID/name, driver, lifecycle operation/phase, status, duration, and Kubernetes identity where observed. They never include command payloads, stdin/stdout/stderr, environment values, credentials, policy payloads, or arbitrary client labels.

## Managed Runtime Contract

Each participating client creates a sandbox with an approved, immutable managed-runtime image digest and uses its documented agent launch command after the sandbox is ready.

Client-supplied environment contains only non-secret correlation values:

```text
OPENSHELL_TRACE_CLIENT_ID
OPENSHELL_TRACE_CLIENT_RUN_ID
OPENSHELL_TRACE_SESSION_ID
OPENSHELL_TRACE_AGENT_NAME
OPENSHELL_TRACEPARENT (optional)
OPENSHELL_TRACESTATE (optional)
OPENSHELL_TRACE_USER_ID (optional pseudonymous value)
```

The gateway validates the client values and injects or overrides platform-controlled values:

```text
OTLP HTTP endpoint
managed runtime service identity and version
approved image digest
sandbox UUID and sandbox name
runtime export mode
platform deployment environment
```

The client cannot select exporter endpoint, transport, headers, sampling policy, image, or service identity.

The runtime starts NeMo Relay only on sandbox loopback, creates the OpenInference `AGENT` root span, propagates accepted W3C context when present, and exports Relay LLM/tool spans directly to Alloy.

Managed-runtime resource identity:

```text
service.name=openshell-managed-agent
service.namespace=<platform domain>
service.version=<managed runtime release>
deployment.environment=<platform environment>
openshell.runtime.image.digest=<trusted digest>
```

The runtime records bounded, non-secret `openshell.client.id`, client run ID, session ID, logical agent name, canonical sandbox identity, and optional pseudonymous user ID. Client identity is an attribute, not a service name, to avoid service-cardinality growth.

## Forge Cutover

Forge migrates from its private Relay launcher to the standard managed runtime as a single change. The existing `forge-sandbox-agent` Relay launcher must be removed once Forge invokes the managed runtime. This prevents duplicate LLM/tool spans.

Forge preserves its separate `forge-orchestrator` control-plane telemetry. It passes workflow and node correlation through the managed contract's client session/run metadata, never through secret environment values.

## Data Flow

```text
Participating client
  -> gateway validates managed-runtime request and creates sandbox
  -> gateway emits OpenTelemetry lifecycle TOOL spans to Alloy
  -> sandbox managed runtime starts loopback NeMo Relay
  -> runtime emits OpenInference AGENT, LLM, and tool spans to Alloy
  -> Alloy batches and forwards traces to Tempo
  -> Grafana queries Tempo
```

## Failure Behavior

- Gateway tracing is disabled unless standard OTEL exporter configuration is present.
- Gateway exporter failure must not alter sandbox authorization, lifecycle, or security policy.
- Runtime Relay failure must not permit an arbitrary exporter endpoint or weaken network policy.
- A missing or incompatible managed runtime image is a hard managed-runtime contract failure. Repair or roll back the image; do not bypass the OpenShell supervisor.
- Background gateway lifecycle spans may be incomplete if the process is terminated before export, but they must never corrupt sandbox state.

## Verification

The implementation is complete only when:

1. The upstream OpenShell release exposes opt-in OTLP gateway configuration and documents it.
2. A gateway sandbox create/delete/exec sequence appears in Tempo as `openshell-gateway` TOOL spans.
3. A standard managed-runtime sandbox emits `openshell-managed-agent` OpenInference AGENT, LLM, and tool spans.
4. W3C context creates a single linked trace where supported; without it, the runtime creates a valid root trace.
5. Gateway lifecycle spans and managed-runtime spans share trusted sandbox correlation attributes.
6. Forge migration emits exactly one set of LLM/tool spans per sandbox and preserves `forge-orchestrator` traces.
7. A non-Forge participating client emits the same managed-runtime trace shape.
8. Span payloads contain no secrets, commands, prompts, or raw output.

## Sources

- Local OpenShell deployment and chart: `components/ai/openshell/`
- Forge sandbox Relay configuration: `components/ai/forge/values.yaml`
- Alloy receiver/exporter: `components/observability/alloy/values.yaml`
- Tempo receiver/retention: `components/observability/tempo/values.yaml`
- OpenShell request tracing seam: https://github.com/NVIDIA/OpenShell/blob/v0.0.77/crates/openshell-server/src/multiplex.rs
- OpenShell sandbox RPC seam: https://github.com/NVIDIA/OpenShell/blob/v0.0.77/crates/openshell-server/src/grpc/sandbox.rs
- OpenTelemetry OTLP/HTTP: https://opentelemetry.io/docs/specs/otlp/#otlphttp
- OpenInference semantic conventions: https://arize-ai.github.io/openinference/spec/semantic_conventions.html
