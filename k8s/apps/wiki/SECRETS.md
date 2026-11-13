# The `wiki/bookstack` Secret

This chart **references** a Secret named `bookstack` and never creates one. The
workloads name it and fail to start if it is absent — that is the behaviour, not
a suggestion.

`nix/services/k3s.nix` creates it, in the wiki pass of the chart apply, from
sops material at `/run/secrets`. That is a deliberate reading of "the chart never
creates a Secret": the chart does not, the activation does, and nothing is ever
typed into a terminal by hand. A Secret typed in by hand is invisible to a
restore — and since the permission model now lives only in the database, the
restore is the one thing that has to be able to bring the credentials and the
configuration back together.

The values come from `nix/services/homelab/homelab-wiki-secrets.yaml`, whose
recipients are the human and mjolnir — **not roque**, which holds the IdP, the
NAS mount and n8n's credential store. That recipient list is plaintext sops
metadata, so the boundary is auditable from a diff.

## What a bad value does

The two OIDC values are the literal string `unset` until the Pocket ID client
exists (RUNBOOK.md section 1). That sentinel is a configuration, not an error:
starting BookStack against a client that does not exist produces a login
redirect to an error page, which reads as a broken wiki rather than an
unconfigured one. An empty value is a mistake rather than a state of the world.

The two are judged apart and they fail the same way: either one skips the wiki
pass, loudly, and lets the rest of the generation land. Neither fails the
activation, so the unit stays green and the deploy says nothing about the wiki.
The four-key comparison in RUNBOOK.md section 4 is what tells you whether the
cluster moved: the pass writes all four keys in one `create secret generic`, so
any key that differs means it applied none of them — including a key you edited
that was not the reason it skipped.

## Rotation

`APP_KEY` can be changed in sops and re-deployed (it invalidates every session,
and nothing else). `DB_PASSWORD` cannot, and activation refuses the attempt
rather than half-applying it.

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

The guard: before creating the Secret, activation reads `DB_PASSWORD` back from
the cluster's `wiki/bookstack` Secret — the record of what was last applied — and
compares. Same value, or no Secret yet, and the pass proceeds. A different value
skips the wiki pass and leaves the Secret alone, so the wiki stays in its
previous, consistent state. **The wiki pass is skipped and the unit stays
green**: from deploy-rs and from `systemctl`, the deploy that refused a rotation
looks like the deploy that applied one. Two things say otherwise. The refusal is on
stderr in the journal of the run that made it, and the Secret keeps the old
`DB_PASSWORD` while the host now reads the new one, so the four-key comparison in
RUNBOOK.md section 4 prints `DB_PASSWORD DIFFERS` — the three keys nobody edited
read `same`, because the pass that would have written them never ran. That is the
price of not rolling a generation back over a password.

If a rotation is ever genuinely needed — a leaked password, or a restore from
a dump made with a different one — do it in one sitting, because BookStack's
live connections break at step 1:

1. `k3s kubectl exec -it -n wiki deploy/wiki-mariadb -- mariadb -u bookstack -p`
   (the old password at the prompt, so it stays out of any argv), then
   `SET PASSWORD = '<the new password>';` — an account can always change its
   own password, and the bookstack account is the only one here that needs
   changing — the root password is not needed for the rotation at all.
2. `k3s kubectl delete secret bookstack -n wiki` — that Secret is the guard's
   memory; deleting it is the statement that the database now agrees with
   sops. The same Secret is the empty-datadir check's install record
   (`nix/services/k3s.nix`), so that detector is blind between this delete and
   step 3's re-activation.
3. Re-activate. The Secret comes back from sops with the new value.
4. `k3s kubectl rollout restart deploy/wiki-bookstack -n wiki`, so the running
   pod's environment matches the account.

Between 2 and 3 a BookStack pod start fails on the missing Secret; between 1
and 4 it fails on the password. That is the whole cost of the rotation, paid
in one window you chose, instead of at an unrelated restart weeks later.

See `RUNBOOK.md` sections 1–3 — create the Pocket ID client, create the
groups, put the values where mjolnir can read them — for what has to happen
before any of this is deployed. Section 4 is the deploy itself.
