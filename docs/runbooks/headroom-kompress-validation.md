# Headroom Kompress + output-shaper validation

Follow-up test plan for the `values.yaml` changes made 2026-06-23. Run this the
day after deploy to confirm the new compression layers actually work in
production and the pod stays healthy under the new memory profile.

## What changed (and why)

`components/ai/headroom/values.yaml` gained:

- `HEADROOM_FORCE_KOMPRESS=1` + `HEADROOM_KOMPRESS_BACKEND=onnx_cpu` — turns on
  ML text compression. Image has no torch, but `onnxruntime` and the int8 model
  are already on the PVC; the backend is pinned to ONNX/CPU so it never looks for
  torch.
- `HEADROOM_OUTPUT_SHAPER=1` + `HEADROOM_EFFORT_ROUTER=1` +
  `HEADROOM_OUTPUT_HOLDOUT=0.1` — trims output tokens; 10% holdout keeps a control
  group so savings are measured, not estimated.
- Memory bumped `1Gi/2Gi` -> `1536Mi/3Gi` — Kompress loads ~261MB model +
  onnxruntime session into the proxy process, which already sat ~1015Mi without it.

Baseline before the change: `avg_compression_pct: 4.7`, `force_kompress: false`,
~7.93M tokens removed, pod RSS ~1015Mi.

## Pre-flight

```sh
export KUBECONFIG=~/.kube/configs/talos-cluster-config
POD=$(kubectl -n ai get pod -l app.kubernetes.io/name=headroom -o jsonpath='{.items[0].metadata.name}')
echo "$POD"
```

## Step 1 — Confirm the new env landed and pod is healthy

```sh
kubectl -n ai get pod "$POD" -o wide
kubectl -n ai exec "$POD" -- sh -c 'env | grep -E "HEADROOM_(FORCE_KOMPRESS|KOMPRESS_BACKEND|OUTPUT_SHAPER|EFFORT_ROUTER|OUTPUT_HOLDOUT)" | sort'
```

Expected: pod `Running 1/1`, low restart count, all five env vars present.

## Step 2 — Confirm Kompress is live in the running proxy

```sh
kubectl -n ai logs "$POD" | head -40
```

Expected in the startup banner: `Optimization: ENABLED`. Watch for any
`onnx` / `kompress` / backend-selection errors. The line
`Code-Aware: DISABLED` is expected and unrelated (that needs the `[code]` image).

```sh
kubectl -n ai exec "$POD" -- sh -c 'curl -s http://localhost:8787/stats' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print('force_kompress:', d['config']['force_kompress'])"
```

Expected: `force_kompress: true` (baseline was `false`).

## Step 3 — Memory headroom check (the real risk)

```sh
kubectl -n ai top pod "$POD"
```

Expected: MEMORY well under the new `3Gi` limit after the proxy has served real
traffic AND loaded the Kompress model. Watch for OOMKill:

```sh
kubectl -n ai get pod "$POD" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
```

Expected: empty (no `OOMKilled`). If this shows `OOMKilled`, raise the limit
further or roll back the Kompress env vars.

## Step 4 — Drive real traffic, then measure the delta

Run a normal opencode coding session (grep/read/bash heavy) for ~15-30 min so the
proxy processes real prompts and tool outputs, then:

```sh
kubectl -n ai exec "$POD" -- sh -c 'curl -s http://localhost:8787/stats' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); c=d['summary']['compression']; print('avg_compression_pct:', c['avg_compression_pct']); print('total_tokens_removed:', c['total_tokens_removed'])"
```

Pass criteria: `avg_compression_pct` climbs above the 4.7 baseline. Even a few
points up means Kompress is compressing prose that previously passed through.

## Step 5 — Output-token savings (measured, via holdout)

```sh
kubectl -n ai exec "$POD" -- sh -c 'curl -s http://localhost:8787/stats' \
  | python3 -m json.tool | grep -iE "output_reduction|output_saved|shap" || echo "no output-shaping fields yet"
```

The holdout-based output savings need enough traffic to populate. If the fields
are absent or zero after Step 4, that layer just needs more requests, not a fix.

## Rollback

If memory spikes past `3Gi`, the pod OOMKills, or backend errors appear in logs,
revert the env block in `values.yaml` (drop the five new vars; optionally keep
the memory bump) and let Renovate/Flux reconcile, or:

```sh
git -C ~/Documents/git-repos/home-ops revert <commit>
```

## Known no-op (do not chase)

`Context Tool: rtk` in the banner is a silent no-op — the `rtk` binary is not in
the `ghcr.io/chopratejas/headroom:nonroot` image (`rtk: not found`), so
`rtk_tokens_avoided` stays `0`. Fixing it needs an image change, not env, and is
out of scope for this test.
