# wiki — activation runbook

The chart deploys BookStack, MariaDB, their storage and their network
containment. It deliberately does **not** configure the wiki: no roles, no
shelves, no permissions. That part is a one-time click-through in the BookStack
UI, specified below, and the database backup is what protects it.

Nothing deploys on its own. Activation reads all four wiki secret values and
judges each of them on two separate states: any one of them still the literal
string `unset` skips the whole wiki pass — loudly, in the journal — rather than
starting a BookStack that redirects login to an error page, and any one of them
empty fails the activation outright. `unset` is a configuration; empty is a
mistake.

## 1. Create the OIDC client in Pocket ID

Administration → OIDC Clients → Add OIDC Client.

Use the **LAN** hostname below. It is `wiki.mjolnir` today because that is the
only name the wiki is served on (the Ingress in `templates/ingress.yaml`);
`wiki.struble.app` does not resolve to this cluster yet. BookStack builds the
redirect URI from `bookstack.appUrl`, so these strings have to match that value
character for character — the render refuses if `appUrl` and the Ingress host
disagree, but nothing can stop the Pocket ID client from being wrong.

| field | value |
|---|---|
| Name | `BookStack` |
| Redirect URI | `https://wiki.mjolnir/oidc/callback` |
| Redirect URIs (logout) | `https://wiki.mjolnir/`<br>`https://wiki.mjolnir/login`<br>`https://wiki.mjolnir/login?prevent_auto_init=true` |
| General → PKCE | **on** — stated as a BookStack requirement since v24.02; stated, not measured (no changelog entry is cited here and nothing in this repo exercises the PKCE path) |

All three logout URIs, not just the callback: BookStack picks one depending on
where you were standing when you logged out, and a mismatch looks like a logout
that silently fails. Copy the client ID and secret — the secret is shown once.

The browser will warn: the certificate is self-signed and regenerated at every
activation, so expect to re-accept it after a redeploy. That is the accepted
cost of serving a LAN name before cert-manager exists; canonical-URLs phase 0
replaces it with one real wildcard. When that happens, re-register these URIs
with the new hostname in the same sitting as the `appUrl` change.

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
sops nix/services/homelab/homelab-wiki-secrets.yaml
```

Replace the two `unset` strings with the client ID and secret. `app-key` and
`db-password` are already generated. That file's recipients are you and mjolnir
only, which is the point of it not being `homelab-secrets.yaml`.

## 4. Deploy

Confirm the LAN DNS record resolves before deploying — `dig +short A
wiki.mjolnir @10.0.0.1` should print `10.0.0.4`. The `.mjolnir` zone is
per-host, not a wildcard, so the record does not arrive on its own.

```
just deploy mjolnir
journalctl -u ai-chart-apply -b | grep -i wiki
kubectl -n wiki get pods
kubectl -n wiki get ingress    # HOSTS should read wiki.mjolnir
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

### 6.6 Revoke

The one step in this section you will do more than once. Taking someone off a
shelf is two actions, and only the first of them is in Pocket ID.

1. **Pocket ID** — remove the user from `family` and/or `plex-users`. To shut
   the wiki to the whole account instead of one audience, remove those groups
   from the client's **Allowed User Groups**: the account then cannot complete
   a wiki login at all, which is the difference between losing a shelf and
   losing the wiki.
2. **BookStack** — end the session that is still carrying the old roles.

Step 2 is not a formality. BookStack runs the group → role sync inside the
login flow and never revisits a session that is already live, so what step 1
changes is picked up at that user's **next login** and not before; until then
the roles they were issued stand, and the shelves they should no longer read
stay readable. The session keys in `templates/bookstack-deployment.yaml`
(`SESSION_ACTIVITY_LIMIT`, `SESSION_TOKEN_TIME`) bound how long an *unattended*
session lives, which caps what forgetting step 2 costs but does not perform it:
a member who keeps the page open refreshes the session and is never aged out.

How to end it. The session driver is the image default, `database`, so the rows
in BookStack's `sessions` table are the sessions, and deleting the ones for that
user makes the cookie in their browser unknown to the app — their next request
lands on the login page and comes back through Pocket ID with the new groups.

```
kubectl -n wiki exec -it deploy/wiki-mariadb -- \
  mysql -u bookstack -p bookstack \
  -e "delete from sessions where user_id = <id>"
```

`-p` carries no value there: it prompts, and the bare word after it is the
database name. The password is `DB_PASSWORD` from the `bookstack` Secret
(`SECRETS.md`), which is the same credential the pod uses.

The heavier version is Users → *name* → Delete, which is the right answer when
the account itself should not come back — and it takes their content with it, so
it is a decision rather than a revocation.

What is stated here and what is checked: the mechanism — sync at login, so a
membership change lands at the next login — is the assumption the whole model
rests on, and 7 exercises the login-time half of it. The SQL above, exactly what
account deletion does to a live session, and the delay from a Pocket ID change
to access actually being gone in a browser have none of them been exercised
against this deployment; they are written from the schema and the image
defaults. That delay in particular is an open measurement, and this section
deliberately records no number for it.

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
  Nothing in this repo schedules a backup yet, so a disk failure today means
  redoing section 6 from memory. When the backup work is filed, the acceptance
  criterion that matters is a rehearsed restore, not a timer that might be
  firing.
- **An empty database reads as healthy — until the activation check says
  otherwise.** If `/var/lib/wiki/mysql` is ever gone — wiped host directory,
  replaced NVMe, the PV recreated against a fresh tmpfiles directory, or a
  partial restore that brought back the uploads tree but not the mysql tree —
  the MariaDB image runs initdb, BookStack's startup `artisan migrate --force`
  builds a fresh empty schema, and `/status` answers 200 because its database
  check is a migrations-row count, which a freshly migrated schema passes.
  The pod reports Ready and serves an empty instance with BookStack's stock
  default roles at the real URL; readiness, probes and the pod-level
  monitoring alerts all stay green. There is no metrics path for row counts,
  so the alarm is an activation-time check at the end of `ai-chart-apply`: a
  Ready BookStack pod coexisting with zero rows in `pages` **and** `shelves`
  fails the unit with a `WIKI EMPTY-DATABASE ALARM` line in the journal, and
  it stays failed until a restore brings the rows back or content exists
  again. Its limits: it observes only when that unit runs (a deploy that
  changes the charts, or a boot), it abstains while no BookStack pod is Ready,
  and a first-ever activation fires it by construction — a brand-new wiki and
  a wiped one are the same rows, so the expected first-run sequence is alarm,
  restore (or start writing), green. Checking by hand:

  ```
  kubectl -n wiki exec deploy/wiki-mariadb -- \
    mariadb -u bookstack -p bookstack -N -B \
    -e "select (select count(*) from pages) as pages, (select count(*) from shelves) as shelves"
  ```

  (`-p` prompts; the password is `DB_PASSWORD` in the `bookstack` Secret, see
  `SECRETS.md`.) Recovery is the rehearsed restore from the note above; with
  no backup, the empty instance is the state of the world and the alarm
  clears once content exists again.
- **A role rename strips membership** unless the role has an Authentication ID.
  When you create a role, give it one if any Pocket ID group maps to it. The
  exception is deliberate and it is in 6.2: the `no-access` default role stays
  without an Authentication ID, because giving it one turns it into a
  group-matched role and stops it being the always-matched default 6.1 depends
  on.
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


  This one is now measured rather than assumed, and it is not the shape the
  chart originally assumed: Pocket ID runs on roque, but the pod resolves
  `auth.struble.app` through public DNS, which answers with the Pangolin edge —
  a public address, not a `10.0.0.x` one. So the discovery request leaves the
  cluster for the edge and tunnels back, and an egress list holding only the
  private segment drops it while every pod still reports Ready. That is why
  `oidc.egressCidrs` carries the edge `/32` alongside `10.0.0.0/24`. The edge
  address is not recorded anywhere else in this repo, so if the VPS moves this
  breaks and nothing here will tell you why until you read this paragraph —
  canonical-URLs phase 0 (CoreDNS views) is the fix that makes the name resolve
  on-LAN and lets the `/32` go away.
- **The LAN route, and what it is not.** The wiki is served at
  `https://wiki.mjolnir` through traefik. That name needs a record in LAN DNS
  pointing at the node (10.0.0.4), and the record is outside this repo. The
  `.mjolnir` zone is per-host rather than a wildcard — `nope-9x7z.mjolnir`
  resolves to nothing — so verify instead of assuming:

  ```
  dig +short A wiki.mjolnir @10.0.0.1
  ```

  A missing record does not announce itself. A correctly rendered Ingress with
  a correctly permitted NetworkPolicy still gives a browser that never receives
  an answer, indistinguishable from the policy rule being missing. DNS first,
  then the policy, then the app.

  **Why `wiki.mjolnir` and not `wiki.struble.app`, which already resolves here
  too.** The LAN resolver answers `wiki.struble.app` with 10.0.0.4 already, so
  routing to it is not the missing piece — the certificate is. `struble.app` is
  on the browser HSTS preload list (inherited through the `.app` TLD), and a
  preloaded domain gets **no "proceed anyway" button**: a self-signed
  certificate is a hard failure with no click-through, not a warning. Serving
  `wiki.struble.app` therefore requires a real certificate, which is
  canonical-URLs phase 0.1 (cert-manager + the `*.struble.app` wildcard). That
  phase is a prerequisite rather than a nicety, and when it lands this hostname
  should be retired in favour of `wiki.struble.app` — the redirect URIs in
  section 1 and `bookstack.appUrl` change together, and BookStack's stored
  absolute URLs need `php artisan bookstack:update-url`.

  Two consequences worth knowing before you rely on it:

  - It is **LAN-only by construction, not by policy.** Nothing listens for the
    wiki on a public interface; the published path still requires the Pangolin
    connector. Turning `ingress.enabled` off removes the route and its
    NetworkPolicy rule in the same apply, so the two cannot drift apart.
  - **Encrypted-DNS devices will not find it.** Android Private DNS and iOS
    encrypted DNS ignore the DHCP-assigned resolver and ask a public resolver,
    which has never heard of `wiki.mjolnir`. Those devices show a wiki that
    looks broken from the same couch as a laptop that works fine. The family
    answer is the LAN-only sibling question in the wiki plan, not a DNS entry.

  Verifying it from the node, without a browser: `curl -sk https://wiki.mjolnir/login`
  should return BookStack's login page. If it hangs instead, the first thing to
  suspect is the ingress-from-traefik rule in `templates/networkpolicy.yaml` —
  the namespace is default-deny, so an Ingress without that rule produces a
  valid object, a Ready pod, and a timeout.

  Before suspecting either: **`ss -tln` shows nothing on 80/443 and that is
  correct.** Traefik is a `LoadBalancer` Service with `EXTERNAL-IP 10.0.0.4`
  (the node), and k3s reaches it with an nftables DNAT — `tcp dport 32443`
  and `31407` translated to the traefik pod — rather than a bound socket, so
  no process ever listens on those ports. Verify with `nft -a list table ip
  nat | grep traefik`, or just ask the endpoint what it serves:

  ```
  curl -skv https://grafana.mjolnir/ 2>&1 | grep -E "subject:|< HTTP"
  ```

  A self-signed `CN=grafana.mjolnir` and a 302 mean the whole LAN path —
  DNAT, traefik, SNI routing, TLS termination — is working for some other app,
  which is the cheapest possible proof that it will work for this one. Same
  DNAT-bypasses-INPUT behaviour the host firewall note in `nix/services/k3s.nix`
  records for the gateway's hostPort 8000.
- **The tunnel.** `wiki.struble.app` is still not published by anything in this
  directory. Until the Pangolin connector lands, the only paths to BookStack are
  the LAN Ingress above and, for debugging, `kubectl -n wiki port-forward
  svc/wiki-bookstack 8080:80`.
  The connector PR carries one wiki-side acceptance item beyond
  reachability: set `bookstack.trustedProxies` (rendered as `APP_PROXIES`)
  to the connector's pod network. It is no longer empty — the LAN Ingress
  already proxies this pod, so it names the pod CIDR — but the connector
  arrives from wherever it arrives, and that value has to cover it too. Left
  short, BookStack trusts no proxy for that source, so login throttling and the
  audit log key on the connector's own address — one person's failed logins
  would lock out the whole household and every audit line would record the same
  source IP. Pocket ID sets `TRUST_PROXY` for the same reason.
