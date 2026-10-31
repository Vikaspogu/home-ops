# Agent Sandbox Manifest Repair Design

## Goal

Restore Argo CD manifest generation and kubeconform validation for `agent-sandbox`.

## Scope

Replace the broken floating release resource in `components/ai/agent-sandbox/kustomization.yaml` with the upstream v0.5.2 all-in-one GitOps asset:

`https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.2/sandbox-with-extensions.yaml`

No namespace, application registration, or controller configuration changes are needed.

## Rationale

The current `releases/latest/download/manifest.yaml` path fails Kustomize resolution and references an asset that upstream renamed in v0.5.2. The selected pinned all-in-one asset is upstream's documented GitOps installation path. It includes a `Namespace` named `agent-sandbox-system`, matching the existing Kustomization and Argo CD application destination.

## Validation

- Render `components/ai/agent-sandbox` using the same Kustomize options as Argo CD.
- Run the existing `scripts/kubeconform.sh` suite.

The pre-change render is the regression reproduction. No dedicated test script is added because the existing component-wide kubeconform path covers this declarative source contract.
