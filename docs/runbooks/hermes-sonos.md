# Hermes Sonos speaker IPs

Hermes receives Sonos speaker addresses from `SONOS_SPEAKER_IPS`, a comma-separated list supplied by the `hermes-agent-secret` Kubernetes Secret. The secret is rendered by External Secrets from the `hermes` 1Password item, so speaker IPs stay out of Git.

The `sonos` CLI can target a speaker directly with `--ip`; it does not currently read `SONOS_SPEAKER_IPS` by itself. Treat the variable as the Hermes-side inventory of known, routable speakers that agents/operators can use when multicast discovery is unreliable.

## Update or rotate speaker IPs

1. Update the `SONOS_SPEAKER_IPS` field in the `hermes` item in the 1Password vault used by the `onepassword-connect` ClusterSecretStore.
   - Format: comma-separated IP addresses, with no spaces required, for example `<speaker-ip>,<speaker-ip>`.
   - Include only Sonos devices reachable from the Hermes pod network on TCP port 1400.
   - Confirm the field exists before syncing this GitOps change; External Secrets will fail to render `hermes-agent-secret` if the template references a missing field.
   - Do not commit real speaker IPs to this repository.
2. Wait for External Secrets to reconcile, or force a refresh if you are operating the cluster manually.
3. Confirm `hermes-agent-secret` was updated in the `ai` namespace.
4. Reloader should restart the Hermes deployment because `components/ai/hermes-agent/values.yaml` annotates the controller with `secret.reloader.stakater.com/reload: hermes-agent-secret`.

## Verify in Kubernetes

```bash
kubectl -n ai get externalsecret hermes-agent
kubectl -n ai get secret hermes-agent-secret -o jsonpath='{.data.SONOS_SPEAKER_IPS}' | wc -c
kubectl -n ai exec deploy/hermes-agent -c app -- sh -c 'test -n "$SONOS_SPEAKER_IPS"'
```

These commands confirm that the ExternalSecret exists, the Secret key has a value, and the Hermes pod receives the environment variable without printing the actual IP list.

If you need to inspect the exact value during a rotation, decode it explicitly:

```bash
kubectl -n ai get secret hermes-agent-secret -o jsonpath='{.data.SONOS_SPEAKER_IPS}' | base64 -d
```

The decoded value should be the comma-separated list from 1Password. Treat it as sensitive and avoid pasting it into logs, tickets, or commits.

## Verify Hermes/Sonos behavior

From a Hermes session with the Sonos skill/tool available, run read-only checks first. Multicast discovery may work when Hermes and Sonos are on the same L2 network:

```bash
sonos discover --format json
sonos group status --format json
```

If discovery is unreliable or blocked, verify one of the configured IPs directly:

```bash
sonos status --ip "<speaker-ip>" --format json
```

Then inspect a named speaker if discovery returns expected rooms:

```bash
sonos status --name "<room name>" --format json
```

Only run playback, volume, grouping, queue, or favorite commands after explicit user confirmation.

## GitOps validation

Before opening a PR, validate the changed manifests:

```bash
kustomize build --load-restrictor=LoadRestrictionsNone --enable-helm components/ai/hermes-agent >/dev/null
./scripts/kubeconform.sh
```

This environment may not have `kubectl`, `kustomize`, `helm`, or `kubeconform` installed, so run the commands from an operator workstation or CI environment when local tools are unavailable.
