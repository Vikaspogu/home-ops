# Hermes NeMo Relay Observability Design

## Goal

Export Hermes Agent lifecycle, LLM, tool, approval, and subagent telemetry as OpenInference OTLP traces through Alloy to Tempo and Grafana.

## Context

The published Hermes image from `agent-platform-custom` commit `85d48a6` installs `nemo-relay==0.3.0` into Hermes's runtime virtual environment and validates the bundled `observability/nemo_relay` plugin. Home-Ops currently runs that image as the `hermes-agent` Deployment in namespace `ai` with `hermes gateway run`.

Alloy already accepts OTLP HTTP on `alloy.observability.svc.cluster.local:4318` and forwards traces to Tempo. Grafana already uses Tempo as a datasource. No NeMo Relay gateway, Service, HTTPRoute, or external credential is required for this telemetry-only integration.

## Decision

Use the in-process Hermes `observability/nemo_relay` plugin, not the `nemo-relay hermes` CLI wrapper or a standalone Relay gateway.

The CLI wrapper is intended for local interactive processes: it creates a temporary loopback gateway and modifies local hook configuration. The in-process plugin matches the existing long-running, ConfigMap-driven Kubernetes Deployment and emits OpenInference-compatible OTLP directly.

## Configuration

1. Enable `observability/nemo_relay` in the existing Hermes plugin list in `hermes-agent-config`.
2. Add a `nemo-relay-plugins.toml` entry to the same ConfigMap. It enables only the NeMo Relay `observability` component and its `openinference` exporter.
3. Configure the exporter with `http_binary` transport and endpoint `http://alloy.observability.svc.cluster.local:4318/v1/traces`.
4. Set stable resource identity using `service_name = "hermes-agent"` and `service_namespace = "ai"`.
5. Mount that ConfigMap key read-only at `/opt/data/nemo-relay-plugins.toml` and set `HERMES_NEMO_RELAY_PLUGINS_TOML` to that path.
6. Update the deployed Hermes image to the CI-produced immutable tag `20260702184336-85d48a6-oci`.

## Explicit Non-Goals

- Do not change `HERMES_BASE_URL`, providers, or model traffic routing.
- Do not add a NeMo Relay sidecar, Deployment, Service, HTTPRoute, or ExternalSecret.
- Do not enable ATOF or ATIF file exporters. They would consume the Hermes PVC and require independent retention and backup policy.
- Do not alter Alloy, Tempo, Grafana, Gateway API, or VolSync configuration.

## Failure Behavior

NeMo Relay exporter delivery failures are fail-open for Hermes work according to NVIDIA's observability configuration: telemetry export errors are reported by the exporter without blocking agent execution. Invalid plugin configuration fails initialization, so rendered-manifest tests must assert the exact component kind, exporter type, endpoint, and mount contract before Argo sync.

## Verification

- A focused rendered-manifest contract test verifies the image tag, plugin enablement, TOML content, environment variable, and ConfigMap mount.
- Kustomize/Helm rendering verifies the component is structurally valid.
- After Argo sync, one Hermes request must produce a `hermes-agent` trace in Tempo, visible through the existing Grafana Tempo datasource.

## Sources

- NVIDIA NeMo Relay Hermes integration: https://docs.nvidia.com/nemo/relay/nemo-relay-cli/hermes
- NVIDIA NeMo Relay observability configuration: https://docs.nvidia.com/nemo/relay/observability-plugin/configuration
- Hermes plugin at the image's pinned upstream release: https://github.com/NousResearch/hermes-agent/tree/2bd1977d8fad185c9b4be47884f7e87f1add0ce3/plugins/observability/nemo_relay
- Home-Ops Hermes component: `components/ai/hermes-agent/`
- Home-Ops Alloy receiver: `components/observability/alloy/values.yaml`
