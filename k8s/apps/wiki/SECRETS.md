# The `wiki/bookstack` Secret

This chart **references** a Secret named `bookstack` and never creates one.
There is no Secret in any rendered manifest of this chart, and no value here
takes a secret value. The workloads name it and fail to start if it is absent —
that is the behaviour, not a suggestion.

This file is documentation. It is not a Secret, and nothing in it is applied.
It is deliberately not named `secrets.yaml`: that name is reserved in this repo
for sops-encrypted files, and two pre-commit hooks enforce the difference —
`detect-secrets` skips `secrets.yaml` on the assumption it is encrypted, and
`sops-encryption` fails the commit if it is not. A plaintext file with that name
cannot exist here, which is the right property for a repo that holds real keys.

## Who creates it

`nix/services/k3s.nix`, in the wiki pass of the chart apply, from sops material
at `/run/secrets` — the same route that already creates `litellm-keys`,
`monitoring-secrets` and `grafana-tls`.

That is a deliberate reading of "the chart never creates a Secret": the chart
does not, the activation script does, and nothing is ever typed into a terminal
by hand. A Secret created by hand is invisible to a restore, and the point of
the seed Job is that the whole model is reproducible from a PR.

The values come from `nix/services/homelab/homelab-secrets-wiki.yaml`, whose
recipients are the human and mjolnir — **not roque**. That recipient list is
plaintext sops metadata, so the boundary is auditable from a diff.

## Keys

Key names are the container's own environment variable names. Not dotted
lowercase, not camelCase: the pod reads these as env vars, and a name that
matches on both sides is one less mapping to get wrong in a manifest diff.

| key | what it is |
|---|---|
| `APP_KEY` | Laravel's application key, `base64:<32 bytes>`. Encrypts session cookies and the like. Rotating it invalidates every session; it does not touch content. |
| `DB_PASSWORD` | the BookStack role's password in MariaDB |
| `OIDC_CLIENT_ID` | from the Pocket ID client, which only a human can create |
| `OIDC_CLIENT_SECRET` | ditto; shown once, at client creation |

The two OIDC values are the literal string `unset` until that client exists.
The apply script refuses to deploy the wiki while it sees that sentinel:
starting BookStack against a client that does not exist produces a login
redirect to an error page, which reads as a broken wiki rather than an
unconfigured one.

## Shape

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: bookstack
  namespace: wiki
type: Opaque
stringData:
  APP_KEY: base64:<32 bytes>
  DB_PASSWORD: <generated>
  OIDC_CLIENT_ID: <pocket id client id>
  OIDC_CLIENT_SECRET: <pocket id client secret>
```

Activation builds it with `--from-file=<key>=<sops path>` rather than
`--from-literal`, so no value ever appears in kubectl's argv, where any local
process could read it out of `/proc/*/cmdline` during activation.

See `RUNBOOK.md` for the four steps that have to happen before any of this is
deployed.
