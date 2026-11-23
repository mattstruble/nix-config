# The `roborock-config` Secret

This chart **references** a Secret named `roborock-config` and never creates
one. The server container reads its whole configuration out of it — the
assembled `config.toml` mounted at `/app/config.toml` and the Cloudflare
token mounted at `/run/secrets/cloudflare-token`, which the config points at
by path (`tls.cloudflare_token_file`).

`nix/services/k3s.nix` creates it, in the roborock pass of the chart apply,
from sops material at `/run/secrets`. Same deliberate reading as the wiki's
SECRETS.md: the chart does not create the Secret, the activation does, and
nothing is typed into a terminal by hand. The values come from
`nix/services/homelab/homelab-roborock-secrets.yaml`, whose recipients are
the human and mjolnir — **not roque**. The oneshot that decrypts and
assembles the config runs on mjolnir; roque only ever sees the Secret's
contents through etcd.

Why the whole `config.toml` is a Secret and not a ConfigMap plus a small
Secret: the app accepts file references only for the Cloudflare token
(`tls.cloudflare_token_file`). The admin password hash, session secret and
protocol PIN hash have no `_file` form and must be inline, so the assembled
file carries secrets and nothing it contains may ship in a ConfigMap.

The key list is `services.k3s.roborockSecretKeys` in `nix/services/k3s.nix`,
and the skeleton the oneshot fills is `roborockConfigText` in the same file —
the FQDN, ports, region, broker mode and TLS settings live there and nowhere
else, because the config is consumed at activation time and no chart
template reads any of it.

## What the `unset` sentinel does

A fresh scope ships all five sops values as the literal string `unset`. That
is a configuration, not an error: the roborock pass skips loudly and the
unit stays green, because deploying a server that cannot issue its own
certificate would produce a pod stuck NotReady — which reads as a broken
cluster rather than an unconfigured app. A part-filled set (some `unset`,
some real) is treated the same way. An empty value is never allowed either.

## Rotation

Unlike the wiki's `DB_PASSWORD`, nothing here is cached in state the Secret
cannot reach: every value can be rotated by editing the sops file,
re-encrypting, and re-deploying. What changes, per value:

- `session-secret` — invalidates every admin dashboard session (logout, not
  lockout).
- `admin-password-hash` — dashboard logins only; takes effect on the next
  login.
- `protocol-pin-hash` — LocalRock and Home Assistant logins; both must
  sign in again with the new PIN. HA's integration entry keeps its server
  URL; only the PIN step repeats.
- `cloudflare-token` — the *running* certificate keeps working; the next
  renewal (`renew_check_seconds` = every 12 h) fails until the new token is
  deployed. A stale token surfaces as renewal failures in the server logs,
  not as an outage.

Nothing restarts a pod when a Secret changes (no checksum annotation, no
reloader), and the `config.toml` mount is a subPath mount, which kubelet
never updates in place: a rotation is complete only after
`kubectl rollout restart deployment/roborock-server -n roborock`. Restarting
is safe at any time the vacuum is not mid-job — the vacuum tolerates a
brief server absence the same way it tolerates any restart, and a restart
never loses onboarding state (the device keys live in `/data`, on the PV).
