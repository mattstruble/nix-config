# wiki — activation runbook

The chart deploys BookStack, MariaDB, their storage and their network
containment. It deliberately does **not** configure the wiki: no roles, no
shelves, no permissions. That part is a one-time click-through in the BookStack
UI, specified below.

The permission model exists in exactly one place: the database.
`nix-config-bk9.8` owns the seed Job that will rebuild it from reviewable code;
until that lands the database holds the permission model alone — what sections 5
and 6 build by hand is the only copy of it, and the database backup is what
protects it.

Sections 1–3 are the hand work, 4 is the deploy, 5–7 are the first-run
configuration and the checks that say it took.

## State of the deployment

Measured against the live cluster and Pocket ID on 2026-11-14. Sections 1–5 ran;
sections 6 and 7 did not, and the group names 6 and 7 were written against are not
the ones in use. Read this before following anything below.

**Live.** Pocket ID 2.18.0 (`pocket-id.service` on roque) with four groups —
`member`, `books`, `admin`, `plex` — and eight accounts, of which only `mestruble`
is in `admin`. The OIDC client is named **Wiki**: confidential, PKCE on, skip
consent on, admitted groups `admin` and `books`. In the cluster, `wiki-bookstack`
and `wiki-mariadb` are `1/1 Running`, `/status` answers 200 through traefik, and the
pod fetches `<issuer>/.well-known/openid-configuration` in 0.27 s. BookStack has the
built-in Admin, Editor, Viewer and Public roles, all with an empty Authentication
ID, plus one audience role **Books User** whose Authentication ID is `books`.

**Not live.** The `books` group has no members, so the one working group → role
mapping grants nothing to anyone. The other seven accounts are in `member`, which
the Wiki client does not admit, so they cannot reach the wiki at all. The wiki is
single-user, and section 7's checks have never been run.

**One of these is load-bearing and accidental.** The Admin role's Authentication ID
is empty, so BookStack matches it to a Pocket ID group by display name: "Admin" →
`admin`, which is a group that exists and that the client admits. That is the whole
reason the admin account is still an admin after login, and section 2 explains what
breaks it.

Sections 1–3 below are the **redo** procedure — a second host, a rotated client, a
rebuilt database. Do not run section 3 against the live scope without reading
`SECRETS.md` first: those four values are live credentials, and `db-password` in
particular cannot be rotated by editing the file.

## 1. Create the OIDC client in Pocket ID

Pocket ID 2.18.0 on roque, `APP_URL = https://auth.struble.app`. Four properties of
that issuer decide this chart's shape, and all four were re-read from its discovery
document on 2026-11-14:

- `groups` is in both `scopes_supported` and `claims_supported`. Without the
  scope the claim is simply absent and every user loses their roles at their next
  login.
- `code_challenge_methods_supported` includes `S256`, and BookStack has required
  PKCE since v24.02.
- `id_token_signing_alg_values_supported` is `RS256`, the only algorithm
  BookStack implements.
- `end_session_endpoint` is published. BookStack's `OIDC_END_SESSION_ENDPOINT` is
  tri-state: `false` disables RP-initiated logout, `true` takes the URL from
  discovery, a string is used verbatim.

### The client

The live client is named **Wiki**. BookStack builds its redirect URI from
`bookstack.appUrl`, so the callback URL must match that value character for
character, and nothing here can stop the Pocket ID client from being wrong.

1. **Administration → OIDC Clients → Add OIDC Client.** Name `Wiki`, and leave it
   **not public** — BookStack has a backend and can hold a secret, which is the
   Public toggle, not the client-type field. Callback URLs:

   ```
   https://wiki.mjolnir/oidc/callback
   https://wiki.struble.app/oidc/callback
   ```

   The second is registered ahead of the Pangolin resource that would serve it;
   `wiki.struble.app` resolves to the node and answers 404 today, so only the first
   is a path a browser can complete.

2. **Create**, then copy the **Client ID** and **Client secret**. The secret is
   shown once.

3. On the client's **General** tab, turn on **PKCE** and **Save** — a toggle
   applied after creation, not a field in the create form.

4. Still on **General**, turn on **Skip Consent Screen**. Pocket ID shows a
   consent screen on first sign-in to any client, and a declined one means the
   `groups` claim never arrives: logins succeed, roles never sync, nothing on
   either side logs an error. BookStack is this cluster's own app, so it is a
   trusted client.

5. On the client's **Access** tab, set **Allowed User Groups** to *Selected user
   groups* and tick `admin` and `books`. A new client admits **nobody** until this
   is set, and everyone else gets "You are not allowed to access this service",
   which reads as a Pocket ID fault rather than an unconfigured client.

### Logout callback URLs

Pocket ID keeps **Logout Callback URLs** as a separate list and matches both lists
**exactly** unless an entry has a wildcard, and BookStack picks a logout URL by
where you were standing when you logged out — a missing entry looks like a logout
that silently does nothing. Register all three paths, for each hostname:

```
https://wiki.mjolnir/
https://wiki.mjolnir/login
https://wiki.mjolnir/login?prevent_auto_init=true
```

A globstar (`**`) covers path segments only, so no wildcard reaches the
`?prevent_auto_init` query string that distinguishes the third entry.

A globstar (`**`) covers path segments only, so no wildcard reaches the
`?prevent_auto_init` query string that distinguishes the third entry.

The certificate is self-signed, so expect to re-accept it after a redeploy — the
accepted cost of a LAN name before cert-manager exists. When canonical-URLs phase
0 ships a real wildcard, re-register these URIs in the same sitting as the
`appUrl` change.

## 2. The groups, and what a group name can do

Pocket ID emits group **names** in the `groups` claim, never friendly names. They
are separate columns and they are equal for all four groups today, which is the
only reason the distinction is not biting.

BookStack's matching, from `app/Access/GroupSyncService.php`: each group name is
trimmed, lower-cased and has its spaces turned into hyphens. A role matches if its
**Authentication ID** — lower-cased, then split on unescaped commas, so one role
can list several groups — equals one of those names. If the Authentication ID is
**empty**, BookStack normalizes the role's **display name** the same way and
compares that instead.

That fallback cuts both ways, and both edges are live here.

- **It grants.** A Pocket ID group named `admin`, `editor` or `viewer` matches the
  built-in role of that name, because those roles have no Authentication ID and
  their display names normalize to exactly those strings. The `admin` group exists
  and the Wiki client admits it, so membership in `admin` *is* BookStack admin —
  not because anyone assigned it, and renaming either side ends it.
- **It strips.** With `OIDC_REMOVE_FROM_GROUPS=true` a login runs
  `roles()->sync(<matched roles>)` and then attaches the default role. Every role
  the groups do not match is detached, including one assigned by hand in the UI.
  So the Admin role the setup CLI created survives only while the group name keeps
  matching it.

The four groups that exist, and what each does:

| group | in the Wiki client | effect in BookStack |
|---|---|---|
| `admin` | yes | matches the built-in **Admin** role by display name |
| `books` | yes | matches **Books User** by Authentication ID; no members, so it grants nothing yet |
| `member` | no | seven of the eight accounts are only here, so they cannot sign in |
| `plex` | no | nothing until the client admits it and a role carries the ID |

A group that exists but is not on the client's **Access** tab cannot sign in at all,
which is the step that gets missed and produces "my wife got access denied from
Pocket ID".

Section 6 needs audience groups that do not exist yet. Create them there, with names
that match no BookStack role display name, before giving them any members.

## 3. Put the values where mjolnir can read them

Filled in 2026-11-11; this is the redo path.

```
sops nix/services/homelab/homelab-wiki-secrets.yaml
```

Set the client ID and secret from section 1. `app-key` and `db-password` are
already generated, and neither is safe to regenerate here: `app-key` invalidates
every session and every stored MFA secret, and `db-password` cannot be rotated by
editing the file at all — activation refuses the attempt and skips the wiki pass,
leaving the unit green (SECRETS.md, "Rotation", for why and for the one-sitting
procedure).
That file's recipients are you and mjolnir only, which is the point of it not
being `homelab-secrets.yaml`.

## 4. Deploy

Confirm the LAN DNS record resolves before deploying — from any machine on the
LAN, `dig +short A wiki.mjolnir @10.0.0.1` should print `10.0.0.4`. The
`.mjolnir` zone is per-host, not a wildcard, so the record does not arrive on its
own. On the laptop (the machine with this repo's checkout):

```
just deploy mjolnir
```

**Then check that the cluster holds the four values the host reads.** A green
deploy is not evidence about the wiki: the wiki pass skips itself on a bad value —
empty or still-`unset` sops value, refused `db-password` rotation, empty render,
failed apply — and the unit exits 0 either way. And `ai-chart-apply` re-runs only
when its own unit file changes, so a sops-only edit never runs it and whatever its
journal holds is from some earlier activation, possibly a good one. Compare values.

All four keys, the cluster against what the activation reads on mjolnir out of
`nix/services/homelab/homelab-wiki-secrets.yaml`. It prints a verdict per key,
never a value, and exits non-zero when any key could not be read; the other keys
still print their verdict. Every read keeps stderr off stdout — a kubectl warning
on a successful read would otherwise be compared as part of the value — and a
failed read prints the command or path, never what it captured:

```
ssh mjolnir 'bash -s' <<'EOF'
rc=0
err=$(mktemp)
if ! sudo -n k3s kubectl -n wiki get secret bookstack -o jsonpath='{.metadata.name}' >/dev/null 2>"$err"; then
  if grep -q NotFound "$err"; then
    echo "no wiki/bookstack Secret — the cluster holds none"
    rm -f "$err"; exit 0
  fi
  echo "READ FAILED — the check could not ask: sudo -n k3s kubectl -n wiki get secret bookstack"
  rm -f "$err"; exit 1
fi
rm -f "$err"
for k in APP_KEY DB_PASSWORD OIDC_CLIENT_ID OIDC_CLIENT_SECRET; do
  f=$(printf '%s' "$k" | tr 'A-Z_' 'a-z-')
  if ! raw=$(sudo -n k3s kubectl -n wiki get secret bookstack -o "jsonpath={.data.$k}" 2>/dev/null); then
    echo "$k  READ FAILED — says nothing about the wiki: kubectl -n wiki get secret bookstack -o jsonpath={.data.$k}"; rc=1; continue
  fi
  if ! wanted=$(sudo -n cat "/run/secrets/services/wiki/$f" 2>/dev/null); then
    echo "$k  READ FAILED — no host value to compare with: /run/secrets/services/wiki/$f"; rc=1; continue
  fi
  if [ -z "$raw" ]; then echo "$k  KEY ABSENT — the Secret exists but does not carry it"
  elif [ "$(printf '%s' "$raw" | base64 -d 2>/dev/null)" = "$wanted" ]; then echo "$k  same"
  else echo "$k  DIFFERS — the wiki pass did not apply the host value"; fi
done
exit $rc
EOF
```

Four `same` lines mean the cluster's Secret is the one this generation's wiki pass
writes — and since you just edited one of the four, `same` on that key means the
pass ran. `DIFFERS` on any key means it wrote none of them: the pass writes all
four in one `create secret generic`. That is why the check reads all four — an
empty `app-key` or a refused `db-password` rotation leaves `OIDC_CLIENT_ID`
looking untouched and correct.

`READ FAILED` is not a verdict about the wiki. A refused `sudo`, an unreachable API
server or a missing `/run/secrets` file prints it with the command or path that
failed and exits 1 — per key, so the keys that could be read still print their
verdict beside it. Fix the access and run it again — restarting the apply cannot
repair a read that never happened. And `no wiki/bookstack Secret` is a statement
about this Secret only: the cluster holds no `wiki/bookstack` Secret. `SECRETS.md`
rotation step 2 (`kubectl delete secret bookstack -n wiki`) puts it in that state
on purpose, as would a recreated namespace; it is not the wiped-database case in
the standing notes, which needs the Secret to be present.

What it cannot see: it compares against what mjolnir holds, so an edit that never
reached mjolnir — a deploy that failed before activation — reads `same`, and there
the `just deploy` output is the evidence. To read the cluster's own value for one
key rather than a verdict, decode it:

```
ssh mjolnir "sudo -n k3s kubectl -n wiki get secret bookstack -o jsonpath='{.data.OIDC_CLIENT_ID}' | base64 -d; echo"
```

and compare it with what you wrote:

```
sops -d --extract '["services"]["wiki"]["oidc-client-id"]' \
  nix/services/homelab/homelab-wiki-secrets.yaml
```

On a `DIFFERS`, a `KEY ABSENT`, or `no wiki/bookstack Secret` — never on a `READ
FAILED` — the pass has to run again. First establish that it is not already
running:

```
ssh mjolnir systemctl show ai-chart-apply -p ActiveState -p SubState
```

`SubState=running` is a pass in flight; `exited` or `dead` is none —
`RemainAfterExit` keeps `ActiveState=active` after the process has exited, so
`ActiveState` on its own never means the pass is running. Nor is a running pass
the deploy you just ran: the unit is `Type=oneshot` with `JobTimeoutUSec=infinity`,
and the activation's `systemctl restart` waits on that job, so a pass in flight is
somebody else's activation — a second terminal, another operator. The pass takes
about 45 seconds end to end (`ExecMainStartTimestamp` to `ExecMainExitTimestamp`). A
`DIFFERS` printed while one is running means the pass has not finished, not that it
applied the wrong value.
Wait and re-check instead of restarting: restarting a running `Type=oneshot`
signals its control group, which aborts the apply chain partway — some
namespaces applied, some not — and leaves nothing to re-run it.

Once `SubState` is not `running`, run the pass now and re-check:

```
ssh mjolnir sudo -n systemctl restart ai-chart-apply
```

That restart is the only way to re-run the pass without changing the unit or
rebooting, and the comparison above is what decides whether to run it. It is not a
wiki-only action: `ai-chart-apply` is the whole chart apply — the prune passes for
cluster, default, gpu, kube-system, monitoring and wiki, and the recreation of the
service Secrets. If the re-check still prints `DIFFERS` once the restarted run has
finished, read the journal of that run:

```
ssh mjolnir sudo -n journalctl -u ai-chart-apply -n 80 --no-pager
```

Look there for a `wiki:` line naming the reason. The wiki pass is the last step of a
long `&&` chain, behind exit-1 guards on unrelated secrets, so a run that died at an
earlier step leaves no wiki reason line for that run at all.

Fix the reason and restart again. Then, on mjolnir:

```
sudo -n k3s kubectl -n wiki get pods
sudo -n k3s kubectl -n wiki get ingress    # HOSTS should read wiki.mjolnir
```

BookStack should be `Running` and `1/1 ready`.

## 5. Bootstrap the admin, bound to your Pocket ID identity

Below, `kubectl` means `sudo -n k3s kubectl`: the k3s kubeconfig is root-owned, so
bare `kubectl` cannot work for the login user on mjolnir.

Find your `sub` claim: it is in the Pocket ID user list, or dump it with
`OIDC_DUMP_USER_DETAILS=true` on the pod and log in once (that env var blocks
logins while it is on, so turn it straight back off).

```
kubectl -n wiki exec -it deploy/wiki-bookstack -- \
  php artisan bookstack:create-admin \
    --name="Matt" --email=matt@struble.dev \
    --external-auth-id=<your-pocket-id-sub>
```

**Do not skip `--external-auth-id`.** `external_auth_id` is the whole link — OIDC
login matches on it and nothing else, and BookStack does not link a local account
to an OIDC identity by email. An admin created without it, or with a mistyped
value, is a second, no-access user the moment you log in via OIDC, and section 6
then hands roles to whichever user the login actually became.

Passing the option also means no password is set — BookStack generates a random
one and you never use it. This is the whole reason to use the CLI rather than the
login form: `AUTH_AUTO_INITIATE=true` sends the login page straight to Pocket ID,
so there is a window where you have a wiki and no way into it.

Confirm it took before moving on. The users table is the record, and this is the
same connection used in 6.6 (`-p` prompts; see there):

```
kubectl -n wiki exec -it deploy/wiki-mariadb -- \
  mariadb -u bookstack -p bookstack \
  -e "select id, name, email, external_auth_id from users"
```

Your row must be there and its `external_auth_id` must hold the `sub` you passed.
There is no `bookstack:list-users` command; `php artisan list` shows what this
image ships. Read the table.

**The image's own admin row survives this.** `admin@admin.com` is created at first
start and holds the Admin role; `bookstack:create-admin` adds a row and removes
none. It cannot authenticate while `AUTH_METHOD=oidc` — `/login` renders only the
OIDC form, which posts to `/oidc/login` and carries no password field — but it is
an Admin principal with a password nobody knows, in the user list, that comes back
to life the day `AUTH_METHOD` changes. Delete it from Settings → Users once your
own row is confirmed above.

## 6. Configure the model

Log in through OIDC. Everything below is Settings → Roles and the permissions
dialog on each entity.

### 6.1 The default role, first

Create a role `no-access` with **nothing** ticked. Then Settings →
Authentication → **Default user role** → `no-access`.

This is the highest-blast-radius setting in the system and it goes first. A login
attaches that role after group matching — `attachDefaultRole()` in
`app/Users/Models/User.php` reads the `registration-role` setting — so whatever it
points at is what every holder of a Pocket ID account receives on first login, on
top of whatever their groups matched. Pointing it at anything other than an empty
role hands out read access by default, silently, to people you have never met.

### 6.2 The audience roles

| role | Authentication ID | permissions |
|---|---|---|
| `no-access` | *(empty)* | none; a group named `no-access` would match it by display name, which is harmless and probably what you want |
| built-in **Admin** | `admin` | set the ID explicitly so the match stops depending on the display name; do not create a second admin role |
| **Books User** *(exists)* | `books` | already correct; the group has no members, so it grants nothing yet |
| `family` | `family` | see 6.3; the Pocket ID group does not exist yet — create it before adding members |
| `plex` | `plex` | see 6.3; the group exists but the client does not admit it |

Authentication ID is what group sync matches against, and while it is empty the
role's **display name** is the match key instead (section 2). So renaming a role in
the UI silently moves who it is granted to, and a new role whose name collides with
an existing Pocket ID group is granted to that group's members on their next login.
Give every audience role an explicit Authentication ID and keep its name away from
the built-in role names.

### 6.3 Strip the global view permissions

On `family` and `plex`, untick every "View all …" permission — view all
books, pages, shelves, attachments. **This is the step that decides whether the
rest of the model means anything.**

BookStack has two ways to grant a read and the global one wins. `EntityPermissionEvaluator`
collects the joint permissions for your roles along the entity chain and returns
`max()` of them, so a role-level `book-view-all` contributes an allow row for every
book and outranks the per-entity deny you just wrote — a role carrying it sees books
it was explicitly never granted. Access for an audience role therefore comes from
the per-entity grants in 6.5 and from nothing else.

### 6.4 Shelves and books

| shelf | viewers | books |
|---|---|---|
| Family | `family`, **Admin** | Printers, Travel, Home |
| Home Apps | `family`, `plex`, **Admin** | Plex |
| Ops | **Admin** | Cluster, Network |

Give each book a chapter named **Internal**. The convention that makes this wiki
usable is that the permission decision is *where you save*: public-facing content
goes in the book, operational detail goes in that book's `Internal` chapter, so
nobody has to open a permissions dialog to do the right thing.

### 6.5 Per-entity grants

For each book: permissions → restrict → tick the roles that should see it, per the
shelf table above.

For each `Internal` chapter: **untick "copy permissions from parent"**, then tick
only **Admin**.

> **The trap in that step, and the one to remember forever.** A new chapter
> inherits its book's grants: absence of an allow is *not* a deny in BookStack —
> it walks up the entity chain and takes whatever the book allows. So creating the
> chapter and leaving the dialog alone gives every audience read access to the
> private chapter, and nothing in the UI looks wrong. This applies to every chapter
> you will ever add, not just these six.

### 6.6 Revoke

The one step in this section you will do more than once. Taking someone off a
shelf is two actions, and only the first of them is in Pocket ID.

1. **Pocket ID** — remove the user from `family` and/or `plex`. To shut the
   wiki to the whole account instead of one audience, remove those groups from the
   client's **Allowed User Groups**: the account then cannot complete a wiki login
   at all, which is the difference between losing a shelf and losing the wiki.
2. **BookStack** — end the session that is still carrying the old roles.

Step 2 is not a formality: BookStack runs the group → role sync inside the login
flow and never revisits a live session, so what step 1 changes lands at that
user's **next login** and not before. The session lifetime bounds how long an
*unattended* session lives, which caps what forgetting step 2 costs but does not
perform it — a member who keeps the page open is never aged out.

How to end it. The session driver is the image default, `database`, so the rows in
BookStack's `sessions` table are the sessions, and deleting that user's rows makes
the cookie in their browser unknown to the app: their next request lands on the
login page and comes back through Pocket ID with the new groups.

```
kubectl -n wiki exec -it deploy/wiki-mariadb -- \
  mariadb -u bookstack -p bookstack \
  -e "delete from sessions where user_id = <id>"
```

`-p` carries no value there: it prompts, and the bare word after it is the
database name. The password is `DB_PASSWORD` from the `bookstack` Secret
(`SECRETS.md`), which is the same credential the pod uses.

The heavier version is Users → *name* → Delete — right when the account itself
should not come back, and it takes their content with it, so it is a decision
rather than a revocation.

What is stated and what is checked: the group → role match and the login-time
`sync()` are read off `GroupSyncService.php` and `OidcService.php` in the running
image, so the mechanism in section 2 is source, not inference. What has not been
exercised here is the other half of this step: the SQL above, what account deletion
does to a live session, and the delay from a Pocket ID change to access being gone
in a browser are written from the schema and the image defaults. That delay
deliberately has no number recorded here.

## 7. Verify

1. Log in as someone whose only group is one the client admits but no role matches
   — `member` once section 6.2 adds it to the client's **Allowed User Groups**.
   Until it is admitted, this check cannot run: that account gets Pocket ID's own
   "not allowed to access this service" and never reaches BookStack. Expect an
   empty dashboard, no books, no shelves. If they see anything, 6.1 did not take.
2. Log in as a `family` member: Family and Home Apps shelves, four books, and no
   `Internal` chapter — not in the book listing, **and not by URL**.
3. Same as `plex`: Home Apps only, Plex only, no `Internal`.
4. Open an `Internal` chapter by URL as `plex`. It must be 404, not a
   redirect to login and not a page.
5. The policy and probe objects, from the apply's own output:

   ```
   sudo -n k3s kubectl -n wiki get networkpolicy
   sudo -n k3s kubectl -n wiki get job -l app.kubernetes.io/part-of=wiki
   ```

   Four `wiki-`prefixed policies, and one `wiki-oidc-egress-*` job with
   `COMPLETIONS 1/1`. The wiki pass runs `kubectl apply --prune` scoped to
   `mjolnir/prune-group=wiki`, and `pruned` is kubectl's word for every removal it
   makes — a rename and an accidental deletion print the same line, so the object
   list is the check, not the log. Between a prune and the CNI programming the
   replacement there is a window in which the old policy's enforcement is gone.

Step 4 is the one that catches 6.5. The listing is generated from a query that
can be correct while the direct fetch is not.

## Standing notes

- **Backups are load-bearing now.** Nothing in this repo schedules a backup yet,
  so a disk failure today means redoing section 6 from memory. When the backup
  work is filed, the acceptance criterion that matters is a rehearsed restore, not
  a timer that might be firing.
- **An empty database reads as healthy.** If `/var/lib/wiki/mysql` is ever gone —
  wiped directory, replaced NVMe, the PV recreated against a fresh tmpfiles
  directory, a partial restore that brought back uploads but not mysql — the MariaDB
  image runs initdb, BookStack's startup `artisan migrate --force` builds a fresh
  empty schema, and `/status` answers 200 because its database check is a
  migrations-row count. The pod reports Ready and serves an empty instance with
  BookStack's stock default roles at the real URL; readiness, probes and pod-level
  alerts all stay green.

  The activation compares the `bookstack` Secret with the MariaDB datadir marker and
  prints the verdict on stderr, then applies anyway: the loss already happened, so
  refusing to apply punishes the operator twice and saves nothing. Its install record
  is that same Secret, so a rotation in progress (`SECRETS.md` step 2 deletes it)
  leaves it silent. No row count can replace it — a wiped wiki and a brand-new one
  are the same rows.

  **BookStack v26.09.2 has no `pages`, `books`, `chapters` or `bookshelves` tables** —
  they are one `entities` table discriminated by `type`, with only the
  `bookshelves_books` join left. A renamed table does not break the deploy, it
  silently disarms a guard written against the old name. Checking by hand (`-p`
  prompts; the password is `DB_PASSWORD` in the `bookstack` Secret, see `SECRETS.md`):

  ```
  kubectl -n wiki exec deploy/wiki-mariadb -- \
    mariadb -u bookstack -p bookstack -N -B \
    -e "select count(*) as entities from entities"
  ```

  `select type, count(*) from entities group by type` says what the rows are. With no
  backup, the empty instance is simply the state of the world.
- **A Retain PV does not rebind after its claim is deleted.** Delete the claim and
  `wiki-data` goes to `Released`, not `Available`, and the PV controller binds only
  `Available` and `Failed` volumes — so deleting the PVC and re-applying the
  manifest leaves the new claim `Pending` forever, with `kubectl describe pv
  wiki-data` still naming the claim and no event naming the cause. Clear the stale
  `claimRef` so the volume returns to `Available`:

  ```
  kubectl patch pv wiki-data -p '{"spec":{"claimRef":null}}'
  ```

  Only after the new claim exists: with the volume `Available` and no claim in the
  wiki namespace, any claim in any namespace asking for this storage class can win
  it — the exact thing the pre-binding exists to prevent. Delete the PVC, re-apply
  the manifest, then patch.
- **The MariaDB root password is unrecoverable by design, and recoverable by hand.**
  It exists once, on the stdout of the container that ran initdb, and nothing holds
  it after that pod's log rotates. The sequence (scale to zero, one server against
  the datadir with the grant tables skipped *and* networking off, set the password
  over the unix socket, delete the ad-hoc pod before scaling back) is in
  `~/llm-wiki/topics/mariadb-root-password-recovery-k3s.md`. Two things make it
  sharp rather than fiddly: two servers on this RWO datadir is corruption, not a
  second chance at uptime, and `--skip-grant-tables` alone leaves the server
  listening on the pod network with no credential.
- **A role rename moves who the role is granted to.** While a role's Authentication
  ID is empty its display name is the group-match key (section 2), so renaming it
  silently changes which Pocket ID members get it at their next login — and a new
  role named after an existing group is granted to that group. Give every role a
  Pocket ID group maps to an explicit Authentication ID. The `no-access` default in
  6.2 is the one role that is not group-matched at all: it is attached by
  `attachDefaultRole()` from the `registration-role` setting, not by a claim, which
  is why giving it an Authentication ID would be a different mechanism rather than a
  safer one.
- **New chapter → set permissions immediately**, per 6.5.

## What this runbook cannot check for you

Three of these were open questions when this file was written. Two have been
answered by measurement against the live cluster, one by inference from the running
image's source, and one is still open.

- **The `groups` claim's shape — settled by inference, not by a capture.** BookStack
  reads `OIDC_GROUPS_CLAIM=groups` with `OIDC_ADDITIONAL_SCOPES=groups`, and the pod
  runs `OIDC_USER_TO_GROUPS=true` with `OIDC_REMOVE_FROM_GROUPS=true`, so every login
  runs `roles()->sync(<matched>)` and detaches whatever the claim did not match. The
  one OIDC account was created with the Admin role at 21:41:47, logged in twice more
  at 21:54 and 21:55, and still holds exactly the Admin role — so the claim arrived
  and carried a name that matched it (`admin`, by display name; see section 2). An
  empty claim would have left that account with nothing but the default role. To
  capture the claim itself rather than infer it, set `OIDC_DUMP_USER_DETAILS=true`
  and log in once; that env var blocks logins while it is on, so turn it straight
  back off.
- **Egress to the issuer — verified from the pod's own vantage, 2026-11-14.**
  BookStack fetches `<issuer>/.well-known/openid-configuration` from inside its own
  pod, and the egress rule allowing it is a CIDR of the **Pangolin edge, not of
  roque**: the pod resolves `auth.struble.app` through public DNS, so the request
  leaves the cluster for the edge and tunnels back. An egress list holding only the
  private segment drops it while every pod still reports Ready. Measured from
  `exec` in the running pod: 200 from the edge address in 0.27 s.
  The `wiki-oidc-egress` CronJob in this chart now makes that request every 30
  minutes and alerts through the path BookStack uses, so a stale CIDR is a page
  rather than a silent outage. What it cannot tell you: a green probe is evidence
  about the route, not about the `iss` string matching or the claim arriving; and
  once the CoreDNS split-horizon work lands (canonical-URLs phase 0) the in-cluster
  answer and the edge address may legitimately diverge, which is the point at which
  the `/32` can go away.
- **The LAN route — verified, 2026-11-14.** `wiki.mjolnir` needs a record in LAN
  DNS pointing at the node (10.0.0.4); the `.mjolnir` zone is per-host rather than
  a wildcard, and a missing record does not announce itself — a correct Ingress and
  a correct NetworkPolicy still give a browser that never receives an answer.
  Measured: `dig +short A wiki.mjolnir @10.0.0.1` → `10.0.0.4`, and
  `curl -sk https://wiki.mjolnir/status` → 200 over the self-signed certificate.
  The rest of this entry is the procedure for the day it does not.

  **Why not `wiki.struble.app`, which already resolves here too.** It does resolve
  to 10.0.0.4; the certificate is the missing piece. `struble.app` is on the browser
  HSTS preload list (inherited through the `.app` TLD), so a self-signed certificate
  is a hard failure with **no "proceed anyway" button**. `wiki.struble.app` therefore
  waits on canonical-URLs phase 0.1 (cert-manager + the `*.struble.app` wildcard),
  and at that cutover this hostname, `bookstack.appUrl` and the section 1 redirect
  URIs move together, with `php artisan bookstack:update-url` rewriting stored
  absolute URLs. Encrypted-DNS devices (Android Private DNS, iOS encrypted DNS)
  ignore the DHCP-assigned resolver and will never resolve `wiki.mjolnir` at all —
  the family answer is the LAN-only sibling question in the wiki plan.

  From the node, `curl -sk https://wiki.mjolnir/login` should return BookStack's
  login page; if it hangs, suspect the ingress-from-traefik rule first — the
  namespace is default-deny, so an Ingress without that rule is a valid object, a
  Ready pod, and a timeout. And **`ss -tln` showing nothing on 80/443 is correct**:
  traefik is a `LoadBalancer` Service with `EXTERNAL-IP 10.0.0.4` reached by
  nftables DNAT (`tcp dport 32443`, `31407`) rather than a bound socket, so
  `nft -a list table ip nat | grep traefik` is where the path lives. Cheaper, ask an
  endpoint that already works what it serves:

  ```
  curl -skv https://grafana.mjolnir/ 2>&1 | grep -E "subject:|< HTTP"
  ```

  A self-signed `CN=grafana.mjolnir` and a 302 prove DNAT, traefik, SNI routing and
  TLS termination for some other app — the cheapest possible proof they work for
  this one. Same DNAT-bypasses-INPUT behaviour the host firewall note in
  `nix/services/k3s.nix` records for the gateway's hostPort 8000.
- **The tunnel — still open.** Nothing in this directory publishes
  `wiki.struble.app`; until the Pangolin connector lands the other path is
  `kubectl -n wiki port-forward svc/wiki-bookstack 8080:80`. The connector PR
  carries one wiki-side acceptance item beyond reachability:
  `bookstack.trustedProxies` (rendered as `APP_PROXIES`) has to name the
  connector's network, not only the pod CIDR the LAN Ingress arrives from. Left
  short, BookStack trusts no proxy for that source, so login throttling and the
  audit log key on the connector's own address — one person's failed logins lock
  out the whole household, and every audit line records the same source IP. Pocket
  ID sets `TRUST_PROXY` for the same reason.
