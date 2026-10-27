# wiki — activation runbook

Everything in this directory is inert until the four steps below are done. The
apply script refuses to deploy the wiki while the two OIDC values are still the
literal string `unset`, and says so in the journal rather than starting a
BookStack that redirects login to an error page.

Nothing here is a secret you should paste into a terminal history. Step 3 uses
`sops`, which edits in place.

## 1. Create the OIDC client in Pocket ID

Administration → OIDC Clients → Add OIDC Client.

| field | value |
|---|---|
| Name | `BookStack` |
| Redirect URI | `https://wiki.struble.app/oidc/callback` |
| Redirect URIs (logout) | `https://wiki.struble.app/`<br>`https://wiki.struble.app/login`<br>`https://wiki.struble.app/login?prevent_auto_init=true` |
| General → PKCE | **on** (BookStack requires it since v24.02) |

All three logout URIs, not just the callback: BookStack picks one depending on
where you were standing when you logged out, and a mismatch looks like a logout
that silently fails. Copy the client ID and secret — the secret is shown once.

## 2. Create the groups

Administration → User Groups. The **Name** field is what matters: Pocket ID
emits group names (not friendly names) in the `groups` claim, and BookStack
matches them lower-cased with spaces turned into hyphens.

| Name | Members |
|---|---|
| `wiki-admin` | you, your wife |
| `family` | whoever gets the household pages |
| `plex-users` | whoever gets Plex help |

Then on the **client's** Access tab, add these to **Allowed User Groups**. A
group that exists but is not allowed on the client cannot sign in to BookStack
at all — this is the step that is easy to miss and produces "my wife got an
access denied from Pocket ID".

## 3. Put the values where mjolnir can read them

```
sops nix/services/homelab/homelab-secrets-wiki.yaml
```

Replace the two `unset` strings with the client ID and secret. `app-key` and
`db-password` are already generated. Save, commit, done — that file's recipients
are you and mjolnir only, which is the point of it not being
`homelab-secrets.yaml`.

## 4. Tell the seed who the admin is

`k8s/apps/wiki/values.yaml` → `seed.admin.externalAuthId` must be **your Pocket
ID `sub` claim** (a UUID). It is visible in the Pocket ID user list, or by
temporarily setting `OIDC_DUMP_USER_DETAILS=true` on the wiki pod and logging in
once — that env var blocks logins while it is on, so turn it straight back off.

This is not bookkeeping. BookStack does not link an existing local account to an
OIDC identity by email. An admin created any other way becomes a second,
no-access user the moment OIDC is the only auth method, and the symptom is an
admin who logs in successfully to an empty wiki.

## 5. Deploy and check

```
just deploy mjolnir
journalctl -u ai-chart-apply -b | grep -i wiki
```

Then the three checks that matter, in this order:

1. `kubectl -n wiki get pods` — BookStack `Running` and `1/1 ready`. Its
   readiness probe is `/status`, which reports database, cache and session
   separately, so a pod that is up but cannot reach MariaDB stays unready
   instead of serving errors.
2. Log in as someone in **no** wiki group. They must land on an empty dashboard
   with no books and no shelves. If they can see anything, the auto-registration
   default role is not the empty `no-access` role and the whole model is open.
3. Log in as a `family` member and as a `plex-users` member. Each must see only
   their own shelves, and neither must see an `Internal` chapter — not in the
   book listing, and not by URL.

## What this runbook cannot check for you

Three things are verified only against a real Pocket ID and a real node, so
treat them as first-run unknowns rather than as things that work:

- **The `groups` claim's shape.** BookStack reads `OIDC_GROUPS_CLAIM=groups` and
  expects an array of names. If group sync silently does nothing, dump the
  claims with `OIDC_DUMP_USER_DETAILS=true` and look at what Pocket ID actually
  sent.
- **Egress to the issuer.** BookStack fetches
  `<issuer>/.well-known/openid-configuration` from inside its own pod. If that
  is unreachable from the cluster network, login never completes and the
  symptom is a redirect that comes back around. The egress rule allowing it is
  in `templates/networkpolicy.yaml`, and it is a CIDR because k3s' policy
  controller has no FQDN rules.
- **The tunnel.** `wiki.struble.app` is not published by anything in this
  directory. The Pangolin connector is a separate change; until it lands the
  wiki is reachable only in-cluster (`kubectl -n wiki port-forward
  svc/wiki-bookstack 8080:80`).

## Not yet built

**There is no backup.** The database and every uploaded image are single-copy on
one NVMe disk on one machine. The design has a phase for this (host systemd
timer, `mysqldump --single-transaction`, uploads tar, encrypted off-node etcd
snapshot, restore rehearsed) and it is tracked; until it lands, treat the wiki
as disposable and do not put anything in it that you would mind retyping.
