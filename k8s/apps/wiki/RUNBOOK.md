# wiki — activation runbook

The chart deploys BookStack, MariaDB, their storage and their network
containment. It deliberately does **not** configure the wiki: no roles, no
shelves, no permissions. That part is a one-time click-through in the BookStack
UI, specified below, and the database backup is what protects it.

Nothing deploys on its own. The apply script refuses while the two OIDC values
are still the literal string `unset`, and says so in the journal rather than
starting a BookStack that redirects login to an error page.

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

Create `wiki-admin`, `family`, `plex-users`. Then on the **client's** Access
tab, add them to **Allowed User Groups**. A group that exists but is not allowed
on the client cannot sign in at all — this is the step that is easy to miss and
produces "my wife got access denied from Pocket ID".

## 3. Put the values where mjolnir can read them

```
sops nix/services/homelab/homelab-secrets-wiki.yaml
```

Replace the two `unset` strings with the client ID and secret. `app-key` and
`db-password` are already generated. That file's recipients are you and mjolnir
only, which is the point of it not being `homelab-secrets.yaml`.

## 4. Deploy

```
just deploy mjolnir
journalctl -u ai-chart-apply -b | grep -i wiki
kubectl -n wiki get pods
```

BookStack should be `Running` and `1/1 ready`. Its readiness probe is `/status`,
which reports database, cache and session separately, so a pod that is up but
cannot reach MariaDB stays unready instead of serving errors.

## 5. Bootstrap the admin, bound to your Pocket ID identity

Find your `sub` claim: it is in the Pocket ID user list, or dump it with
`OIDC_DUMP_USER_DETAILS=true` on the pod and log in once (that env var blocks
logins while it is on, so turn it straight back off).

```
kubectl -n wiki exec -it deploy/wiki-bookstack -- \
  php artisan bookstack:create-admin \
    --name="Matt" --email=matt@struble.app \
    --external-auth-id=<your-pocket-id-sub>
```

**Do not skip `--external-auth-id`.** BookStack does not link an existing local
account to an OIDC identity by email. An admin created without it is a second,
no-access user the moment you log in via OIDC, and the symptom is an admin who
authenticates successfully to an empty wiki with no obvious way back.

Passing the option also means no password is set — BookStack generates a random
one and you never use it. This is the whole reason to use the CLI rather than
the login form: `AUTH_AUTO_INITIATE=true` sends the login page straight to
Pocket ID, so there is a window where you have a wiki and no way into it.

## 6. Configure the model

Log in through OIDC. Everything below is Settings → Roles and the permissions
dialog on each entity.

### 6.1 The default role, first

Create a role `no-access` with **nothing** ticked. Then Settings →
Authentication → **Default user role** → `no-access`.

This is the highest-blast-radius setting in the system and it goes first.
`OIDC_REMOVE_FROM_GROUPS=true` makes the empty role "always matched", so
whatever the default points at is what every holder of a Pocket ID account
receives on first login. Pointing it at anything else hands out read access by
default, silently, to people you have never met.

### 6.2 The audience roles

| role | Authentication ID | permissions |
|---|---|---|
| `no-access` | *(empty)* | none |
| `wiki-admin` | `wiki-admin` | leave the built-in **Admin** role alone; give it the Authentication ID `wiki-admin` rather than creating a second admin role |
| `family` | `family` | see 6.3 |
| `plex-users` | `plex-users` | see 6.3 |

Authentication ID is what Pocket ID group sync matches against. Without it
BookStack falls back to the role's display name, so **renaming a role in the UI
silently strips every member's role at their next login**. With it, display
names are cosmetic and safe to change.

### 6.3 Strip the global view permissions

On `family` and `plex-users`, untick every "View all …" permission — view all
books, pages, shelves, attachments. **This is the step that decides whether the
rest of the model means anything.**

BookStack has two independent ways to grant a read and the global one wins:
`book-view-all` means "every book, always", and it is evaluated *before* entity
permissions. A role carrying it sees books it was explicitly never granted.
BookStack's own Viewer role ships with five of these, so a role created by
cloning a preset starts open. Measured: with one of them ticked a family user
opened the Cluster book; without, 404.

What these roles need is no global permissions at all. Access comes entirely
from the per-entity grants in 6.5.

### 6.4 Shelves and books

| shelf | viewers | books |
|---|---|---|
| Family | `family`, `wiki-admin` | Printers, Travel, Home |
| Home Apps | `family`, `plex-users`, `wiki-admin` | Plex |
| Ops | `wiki-admin` | Cluster, Network |

Give each book a chapter named **Internal**. The convention that makes this
wiki usable is that the permission decision is *where you save*: public-facing
content goes in the book, operational detail goes in that book's `Internal`
chapter. Nobody should ever have to open a permissions dialog to do the right
thing.

### 6.5 Per-entity grants

For each book: permissions → restrict → tick the roles that should see it, per
the shelf table above.

For each `Internal` chapter: **untick "copy permissions from parent"**, then
tick only `wiki-admin`.

> **The trap in that step, and the one to remember forever.** A new chapter
> inherits its book's grants. Absence of an allow is *not* a deny in BookStack —
> it walks up the entity chain and takes whatever the book allows. So creating
> the chapter and leaving the dialog alone gives every audience read access to
> the private chapter, and nothing in the UI looks wrong. This applies to every
> chapter you will ever add, not just these six.

## 7. Verify

1. Log in as someone in **no** wiki group. Empty dashboard, no books, no
   shelves. If they see anything, 6.1 did not take.
2. Log in as a `family` member: Family and Home Apps shelves, four books, and no
   `Internal` chapter — not in the book listing, **and not by URL**.
3. Same as `plex-users`: Home Apps only, Plex only, no `Internal`.
4. Open an `Internal` chapter by URL as `plex-users`. It must be 404, not a
   redirect to login and not a page.

Step 4 is the one that catches 6.5. The listing is generated from a query that
can be correct while the direct fetch is not.

## Standing notes

- **Backups are load-bearing now.** The permission model exists in exactly one
  place: the database. There is no seed to re-run and no manifest to re-apply.
  Until the backup ticket lands, a disk failure means redoing section 6 from
  memory. See the ticket; the acceptance criterion that matters is a rehearsed
  restore, not a timer that might be firing.
- **A role rename strips membership** unless the role has an Authentication ID.
  Give every role one when you create it.
- **New chapter → set permissions immediately**, per 6.5.

## What this runbook cannot check for you

Three things are verified only against a real Pocket ID and a real node, so
treat them as first-run unknowns rather than as things that work:

- **The `groups` claim's shape.** BookStack reads `OIDC_GROUPS_CLAIM=groups` and
  expects an array of names. If group sync silently does nothing, dump the
  claims with `OIDC_DUMP_USER_DETAILS=true` and look at what Pocket ID actually
  sent.
- **Egress to the issuer.** BookStack fetches
  `<issuer>/.well-known/openid-configuration` from inside its own pod. If that
  is unreachable from the cluster network, login never completes and the symptom
  is a redirect that comes back around. The egress rule allowing it is in
  `templates/networkpolicy.yaml`, and it is a CIDR because k3s' policy
  controller has no FQDN rules.
- **The tunnel.** `wiki.struble.app` is not published by anything in this
  directory. Until the Pangolin connector lands the wiki is reachable only
  in-cluster: `kubectl -n wiki port-forward svc/wiki-bookstack 8080:80`.
