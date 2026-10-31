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
by hand. A Secret typed in by hand is invisible to a restore — and since the
permission model now lives only in the database, the restore is the one thing
that has to be able to bring the credentials and the configuration back
together.

The values come from `nix/services/homelab/homelab-wiki-secrets.yaml`, whose
recipients are the human and mjolnir — **not roque**. That recipient list is
plaintext sops metadata, so the boundary is auditable from a diff.

## Keys

Key names are the container's own environment variable names. Not dotted
lowercase, not camelCase: the pod reads these as env vars, and a name that
matches on both sides is one less mapping to get wrong in a manifest diff.

| key | what it is |
|---|---|
| `APP_KEY` | Laravel's application key, `base64:<32 bytes>`. Encrypts session cookies and the like. Rotating it invalidates every session; it does not touch content. |
| `DB_PASSWORD` | the BookStack role's password in MariaDB. **Not rotatable** through sops — see Rotation below |
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

## Rotation

`APP_KEY` can be changed in sops and re-deployed (it invalidates every
session, and nothing else). `DB_PASSWORD` cannot, and activation refuses the
attempt rather than half-applying it.

The reason is the MariaDB image: it reads `MARIADB_USER` and `MARIADB_PASSWORD`
only while the data directory is empty. From then on the account's password
lives in the database, and re-applying the Secret does not touch it. A rotated
`db-password` would therefore update the Secret and BookStack's environment
while the bookstack account kept the old password forever — and because
nothing here restarts a pod when a Secret changes (no checksum annotation, no
reloader), the mismatch would surface as Access denied at the next BookStack
start: `/status` 500, pod NotReady, days or weeks after the rotation and fully
detached from it. Refusing at activation is the cheaper failure. The
alternative — activation running `ALTER USER` and both pod templates carrying
a Secret checksum so the workloads move with the credential — is machinery a
two-person homelab does not need for a password that rotates about never, and
it is the machinery this file's own argument is against: the restore, not a
controller, is what is supposed to bring credentials and configuration back
together.

The guard: before creating the Secret, activation reads `DB_PASSWORD` back
from the cluster's `wiki/bookstack` Secret — the record of what was last
applied — and compares. Same value, or no Secret yet, and the pass proceeds.
A different value fails the activation with the procedure below in its
message, and the Secret is left alone, so the wiki stays in its previous,
consistent state.

If a rotation is ever genuinely needed — a leaked password, or a restore from
a dump made with a different one — do it in one sitting, because BookStack's
live connections break at step 1:

1. `k3s kubectl exec -it -n wiki deploy/wiki-mariadb -- mariadb -u bookstack -p`
   (the old password at the prompt, so it stays out of any argv), then
   `SET PASSWORD = '<the new password>';` — an account can always change its
   own password, and the bookstack account is the only one here that needs
   changing (the root password died with the initdb pod's stdout).
2. `k3s kubectl delete secret bookstack -n wiki` — that Secret is the guard's
   memory; deleting it is the statement that the database now agrees with
   sops.
3. Re-activate. The Secret comes back from sops with the new value.
4. `k3s kubectl rollout restart deploy/wiki-bookstack -n wiki`, so the running
   pod's environment matches the account.

Between 2 and 3 a BookStack pod start fails on the missing Secret; between 1
and 4 it fails on the password. That is the whole cost of the rotation, paid
in one window you chose, instead of at an unrelated restart weeks later.

See `RUNBOOK.md` for the four steps that have to happen before any of this is
deployed.
