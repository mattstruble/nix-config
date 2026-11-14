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

## 1. Create the OIDC client in Pocket ID

Pocket ID 2.18.0 on roque, `APP_URL = https://auth.struble.app`. What this chart
asks of that issuer is safe because each of these was read off its live discovery
document rather than assumed:

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

Use the **LAN** hostname — `wiki.mjolnir` is the only name the wiki is served on
(see the HSTS note at the end). BookStack builds its redirect URI from
`bookstack.appUrl`, so the callback URL must match that value character for
character, and nothing here can stop the Pocket ID client from being wrong.

1. **Administration → OIDC Clients → Add OIDC Client.** Name `BookStack`, client
   type **confidential** — BookStack has a backend and can hold a secret.
   Callback URL:

   ```
   https://wiki.mjolnir/oidc/callback
   ```

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
   groups* and tick `wiki-admin`, `family`, `plex-users` — they come from section
   2, so nothing to tick yet is expected. A new client admits **nobody** until
   this is set, and everyone else gets "You are not allowed to access this
   service", which reads as a Pocket ID fault rather than an unconfigured client.

### Logout callback URLs

Pocket ID keeps **Logout Callback URLs** as a separate list and matches both lists
**exactly** unless an entry has a wildcard, and BookStack picks a logout URL by
where you were standing when you logged out — a missing entry looks like a logout
that silently does nothing. Register all three:

```
https://wiki.mjolnir/
https://wiki.mjolnir/login
https://wiki.mjolnir/login?prevent_auto_init=true
```

A globstar (`**`) covers path segments only, so no wildcard reaches the
`?prevent_auto_init` query string that distinguishes the third entry.

The certificate is self-signed, so expect to re-accept it after a redeploy — the
accepted cost of a LAN name before cert-manager exists. When canonical-URLs phase
0 ships a real wildcard, re-register these URIs in the same sitting as the
`appUrl` change.

## 2. Create the groups

Administration → User Groups. The **Name** field is what matters: Pocket ID emits
group names (not friendly names) in the `groups` claim, and BookStack matches
them lower-cased with spaces turned into hyphens.

Create `wiki-admin`, `family`, `plex-users`. Then finish the client's **Access**
tab from section 1 step 5 — a group that exists but is not allowed on the client
cannot sign in at all, which is the step that gets missed and produces "my wife
got access denied from Pocket ID".

## 3. Put the values where mjolnir can read them

```
sops nix/services/homelab/homelab-wiki-secrets.yaml
```

Replace the two `unset` strings with the client ID and secret. `app-key` and
`db-password` are already generated. That file's recipients are you and mjolnir
only, which is the point of it not being `homelab-secrets.yaml`.

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
the deploy you just ran: a deploy that restarts this unit waits for it (measured
here — the unit's own start and exit timestamps, 09:41:26 and 09:42:11, both
fall inside that deploy's ssh session), so a pass in flight is somebody else's
activation — a second terminal, another operator. A `DIFFERS` printed while one
is running means the pass has not finished, not that it applied the wrong value.
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
    --name="Matt" --email=matt@struble.app \
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

## 6. Configure the model

Log in through OIDC. Everything below is Settings → Roles and the permissions
dialog on each entity.

### 6.1 The default role, first

Create a role `no-access` with **nothing** ticked. Then Settings →
Authentication → **Default user role** → `no-access`.

This is the highest-blast-radius setting in the system and it goes first.
`OIDC_REMOVE_FROM_GROUPS=true` makes the empty role "always matched", so whatever
the default points at is what every holder of a Pocket ID account receives on
first login. Pointing it at anything else hands out read access by default,
silently, to people you have never met.

### 6.2 The audience roles

| role | Authentication ID | permissions |
|---|---|---|
| `no-access` | *(empty)* | none |
| `wiki-admin` | `wiki-admin` | leave the built-in **Admin** role alone; give it the Authentication ID `wiki-admin` rather than creating a second admin role |
| `family` | `family` | see section 6.3 |
| `plex-users` | `plex-users` | see section 6.3 |

Authentication ID is what Pocket ID group sync matches against. Without it
BookStack falls back to the role's display name, so **renaming a role in the UI
silently strips every member's role at their next login**. With it, display names
are cosmetic and safe to change.

### 6.3 Strip the global view permissions

On `family` and `plex-users`, untick every "View all …" permission — view all
books, pages, shelves, attachments. **This is the step that decides whether the
rest of the model means anything.**

BookStack has two independent ways to grant a read and the global one wins:
`book-view-all` is evaluated *before* entity permissions, so a role carrying it
sees books it was explicitly never granted — and the Viewer role it can be cloned
from ships with five of them. Measured: with one ticked a family user opened the
Cluster book; without, 404. What these roles need is no global permissions at all;
access comes entirely from the per-entity grants in 6.5.

### 6.4 Shelves and books

| shelf | viewers | books |
|---|---|---|
| Family | `family`, `wiki-admin` | Printers, Travel, Home |
| Home Apps | `family`, `plex-users`, `wiki-admin` | Plex |
| Ops | `wiki-admin` | Cluster, Network |

Give each book a chapter named **Internal**. The convention that makes this wiki
usable is that the permission decision is *where you save*: public-facing content
goes in the book, operational detail goes in that book's `Internal` chapter, so
nobody has to open a permissions dialog to do the right thing.

### 6.5 Per-entity grants

For each book: permissions → restrict → tick the roles that should see it, per the
shelf table above.

For each `Internal` chapter: **untick "copy permissions from parent"**, then tick
only `wiki-admin`.

> **The trap in that step, and the one to remember forever.** A new chapter
> inherits its book's grants: absence of an allow is *not* a deny in BookStack —
> it walks up the entity chain and takes whatever the book allows. So creating the
> chapter and leaving the dialog alone gives every audience read access to the
> private chapter, and nothing in the UI looks wrong. This applies to every chapter
> you will ever add, not just these six.

### 6.6 Revoke

The one step in this section you will do more than once. Taking someone off a
shelf is two actions, and only the first of them is in Pocket ID.

1. **Pocket ID** — remove the user from `family` and/or `plex-users`. To shut the
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

What is stated and what is checked: sync at login is the assumption the whole model
rests on, and 7 exercises it. The SQL above, what account deletion does to a live
session, and the delay from a Pocket ID change to access being gone in a browser
are written from the schema and the image defaults, not exercised against this
deployment; that delay deliberately has no number recorded here.

## 7. Verify

1. Log in as someone in **no** wiki group. Empty dashboard, no books, no
   shelves. If they see anything, 6.1 did not take.
2. Log in as a `family` member: Family and Home Apps shelves, four books, and no
   `Internal` chapter — not in the book listing, **and not by URL**.
3. Same as `plex-users`: Home Apps only, Plex only, no `Internal`.
4. Open an `Internal` chapter by URL as `plex-users`. It must be 404, not a
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
- **An empty database reads as healthy.** If
  `/var/lib/wiki/mysql` is ever gone — wiped directory, replaced NVMe, the PV
  recreated against a fresh tmpfiles directory, a partial restore that brought back
  uploads but not mysql — the MariaDB image runs initdb, BookStack's startup
  `artisan migrate --force` builds a fresh empty schema, and `/status` answers 200
  because its database check is a migrations-row count. The pod reports Ready and
  serves an empty instance with BookStack's stock default roles at the real URL;
  readiness, probes and pod-level alerts all stay green.

  **One automated check exists now; the row-counting one did not survive.** The
  activation compares the `bookstack` Secret with the MariaDB datadir marker and
  prints the wiped-database verdict on stderr — the Secret-present/marker-absent
  paragraph below — and its install record is that same Secret, so a rotation in
  progress (`SECRETS.md` step 2 deletes it) leaves it silent. The alarm built
  before it — poll for a Ready BookStack pod, count content rows, exit 1 on
  zero — could not tell a wiped wiki from a brand-new one, because they are the
  same rows; it fired on the wiki's first deploy. A data-loss indicator that
  blocks deployments is not an indicator, it is an outage; if the wiki grows a
  metrics endpoint the check belongs in a PrometheusRule, where a verdict is an
  alert a human can dismiss. And the honest trigger is a change of expectation,
  not a row count: zero rows is correct the day
  the wiki is installed and alarming the day after it had hundreds, and only you
  know which day it is.

  **Why `entities`.** BookStack v26.09.2 has no `pages`, `books`, `chapters` or
  `bookshelves` tables — they are one `entities` table discriminated by `type`,
  with only the `bookshelves_books` join left. A renamed table does not break the
  deploy, it silently disarms a guard written against the old name: the removed
  check errored on a missing table, discarded stderr, and read its own empty stdout
  as "inconclusive". Checking by hand (`-p` prompts; the password is `DB_PASSWORD`
  in the `bookstack` Secret, see `SECRETS.md`):

  ```
  kubectl -n wiki exec deploy/wiki-mariadb -- \
    mariadb -u bookstack -p bookstack -N -B \
    -e "select count(*) as entities from entities"
  ```

  `select type, count(*) from entities group by type` says what the rows are. With
  no backup, the empty instance is simply the state of the world. The activation
  reports the Secret-present/marker-absent combination and applies anyway: the loss
  already happened, so refusing to apply would punish the operator twice and save
  nothing.
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
- **Recover the MariaDB root password with the grant tables skipped.** That
  password exists once, on the stdout of the container that ran initdb
  (`MARIADB_RANDOM_ROOT_PASSWORD`), and kubelet persists that stdout to a log
  file on the node; once the pod that ran initdb is gone and the file has
  rotated, nothing holds the value. Getting in again is a hand sequence, and
  step 2 is the one state in which the wiki's data is served with no
  authentication at all — which is why the networking half of it is not
  decoration:

  1. `kubectl -n wiki scale deploy/wiki-mariadb --replicas=0`, and wait for the
     pod to disappear from `kubectl -n wiki get pods`. Two servers on this RWO
     datadir is corruption, not a second chance at uptime — the same reason the
     Deployment strategy is `Recreate`. Nothing in the cluster refuses the
     second server either: `ReadWriteOnce` restricts nodes, not pods, and there
     is one node.

     Nothing holds the scale at zero either, and nothing in the chart's apply
     restores it: the wiki pass is a client-side `kubectl apply --prune`, not a
     server-side one (`nix/services/k3s.nix`), and under client-side three-way
     merge a field whose last-applied value equals the new file's value is left
     untouched — so `--replicas=0` survives every re-apply of the unchanged
     manifest, the boot run of `ai-chart-apply` and the Sat 02:30
     `system.autoUpgrade` activation included. You are the only thing that
     scales it back, so the window is one sitting. The durable hazard is the
     ad-hoc pod in step 2: kubelet restarts a bare pod after a reboot.

     The check for this step, before step 2 starts: `kubectl -n wiki get pods
     -l app.kubernetes.io/component=database` prints no rows.

  2. Start one server against the datadir with the grant tables skipped *and*
     networking off, from a pod built out of the Deployment's own pod spec
     (`kubectl -n wiki get deploy wiki-mariadb -o yaml`, keep the pod template,
     drop the Deployment wrapper) rather than `kubectl run`, because the mount
     has to be the Deployment's: claim `wiki-data`, `mountPath: /var/lib/mysql`,
     `subPath: mysql`. The extracted manifest needs three fields the pod
     template does not carry: `apiVersion: v1`, `kind: Pod`, and a
     `metadata.name` that is not the Deployment's — the name below is
     `wiki-mariadb-recovery`. The claim root is the PV's host path `/var/lib/wiki`,
     whose `mysql/` subtree is the datadir and whose `bookstack/` subtree is
     BookStack's `/config`; against the root there is no `./ibdata1` and the
     server is not looking at the wiki's grant tables. Keep the `run` and `tmp`
     emptyDirs and the uid/gid; drop the probes, which are the Deployment's
     readiness story and a restart here restarts the recovery. Override the
     command so the image's entrypoint never runs:

     ```
     command: ["mariadbd", "--skip-grant-tables", "--skip-networking"]
     ```

     Three conditions this step carries: the entrypoint is the thing that would
     run initdb against a directory it believes is empty; `--skip-grant-tables`
     alone leaves the server listening on the pod network with no credential,
     and the only thing between that and the rest of the cluster is
     `wiki-default-deny` — a policy in a chart you are not applying right now,
     which `--skip-networking` does not depend on; and the pod's
     `app.kubernetes.io/component: database` label is the Deployment's selector,
     whose ReplicaSet adopts orphan pods matching it and then deletes the
     adoption while the Deployment is at zero — drop that label.

     Create the pod, and let it tell you it is up before you trust anything it
     says about the datadir:

     ```
     kubectl -n wiki apply -f wiki-mariadb-recovery.yaml
     kubectl -n wiki get pod wiki-mariadb-recovery
     ```

     `Running` is the go-ahead. `CreateContainerConfigError`, `RunContainerError`
     or `CrashLoopBackOff` means the manifest you extracted is not the pod the
     Deployment runs — fix the manifest before the next block touches the tree.

     Before any password is touched, check that the server is against the real
     datadir:

     ```
     kubectl -n wiki exec -it wiki-mariadb-recovery -- sh -c \
       'ls -l /var/lib/mysql/ibdata1; \
        mariadb -u root --socket=/run/mysqld/mysqld.sock -e "SHOW DATABASES"'
     ```

     `ibdata1` there and `bookstack` in the list is the proof. `ERROR 2002`
     (Can't connect to local server) means the server is not answering yet:
     re-run the block — a timing failure is not a verdict about the datadir.
     Only once the server answers and either is still missing is the mount
     wrong: fix the mount. Making the directory work with the image entrypoint
     or `mariadb-install-db` is the destructive answer — either writes a fresh
     schema into the tree that holds BookStack's `/config` and uploads.

  3. Over the unix socket — `--skip-networking` leaves no TCP port, and the
     socket is the `run` emptyDir at `/run/mysqld/mysqld.sock`. Generate the
     replacement rather than inventing one, and put the result where you keep
     credentials: it replaces initdb's generated password and is recorded
     nowhere else.

     ```
     openssl rand -base64 24
     ```

     Run it on your own machine: openssl is not on mjolnir's PATH (the
     activation binds it explicitly for its own use).

     The statements go on stdin, never through `-e`: `mariadb -e "SET PASSWORD
     ... = 'x'"` puts the value in the process arguments, readable by anything
     on the node that reads `ps`. And the value reaches the pipe through
     `read -rs`, not typed into a heredoc — a password typed at the prompt
     lands in the operator's shell history.

     ```
     read -rs -p 'new root password: ' PW
     { echo 'FLUSH PRIVILEGES;'
       echo "SET PASSWORD FOR 'root'@'localhost' = '$PW';"; } | \
       kubectl -n wiki exec -i wiki-mariadb-recovery -- \
         mariadb -u root --socket=/run/mysqld/mysqld.sock
     unset PW
     ```

     The flush is load-bearing: under `--skip-grant-tables` the grant tables are
     not loaded, and until they are the server refuses `SET PASSWORD`. The check
     is that the client prints nothing — it is silent on success and names the
     statement on failure. The value itself is not checkable from here: while
     the grant tables are skipped the server authenticates nobody, so a sign-in
     that succeeds proves nothing about the password. It is proved by the check
     after step 4, the first one that runs against a server holding grant
     tables.

  4. Delete the ad-hoc pod — that is the stop, and only the delete is one. The
     pod came from the Deployment's pod template, which sets no
     `restartPolicy`, so the API server defaulted it to `Always`: killing
     `mariadbd` inside it brings the grant-tables-skipped server back inside the
     kubelet backoff. Coming back on the next boot is the second reason, not the
     first.

     ```
     kubectl -n wiki delete pod wiki-mariadb-recovery
     kubectl -n wiki get pod wiki-mariadb-recovery
     ```

     The second command must answer `Error from server (NotFound)`: the
     delete's pass condition asserted by name, because the pod's own name
     matches the `wiki-mariadb-*` row of the label-scoped check below — a
     silently failed delete still prints two matching rows there while the
     grant-tables-skipped server is still running.

     Re-run step 1's check immediately before scaling up —
     `kubectl -n wiki get pods -l app.kubernetes.io/component=database` must
     still print no rows. If a database pod appeared while you were working, the
     ad-hoc server has to go first: two servers on this datadir is the
     corruption from step 1, not a race you can win. Then scale back to one:

     ```
     kubectl -n wiki scale deploy/wiki-mariadb --replicas=1
     kubectl -n wiki rollout status deploy/wiki-mariadb --timeout=10m
     ```

     Wait for the rollout before both the pod-list check below and the
     password check at the end of the sequence: `Running` is not "the server
     answers", and a check run against a pod that is not up yet reads as
     failure, not as verdict.

     The check that the unauthenticated server is gone and the Deployment's own
     pods are the only ones left:

     ```
     kubectl -n wiki get pods -l app.kubernetes.io/part-of=wiki
     ```

     Exactly two rows, `wiki-bookstack-*` and `wiki-mariadb-*`, and no ad-hoc
     one. A third row is a bare pod: it survives a reboot, and the Deployment's
     pods do not return on their own, so delete it and scale again rather than
     leaving it.

  The check that the whole sequence worked (`-p` prompts; the password is the
  one just set, and this is the first point in the sequence where a password is
  checked at all):

  ```
  kubectl -n wiki exec -it deploy/wiki-mariadb -- mariadb -u root -p -e 'SELECT 1'
  ```

  That prints `1`, and a wiki login through OIDC succeeds. BookStack
  authenticates as `bookstack`, which this sequence never touches, so a
  BookStack pod left not-`1/1 Ready` means something else moved. Nothing goes
  back into the repo: the root password is in no manifest and no Secret, and
  `DB_PASSWORD` is the bookstack account — a different credential, rotated the
  way `SECRETS.md` says, not this.
- **A role rename strips membership** unless the role has an Authentication ID, so
  give every role a Pocket ID group maps to one. The `no-access` default is the
  deliberate exception in 6.2: an Authentication ID would make it a group-matched
  role and stop it being the always-matched default 6.1 depends on.
- **New chapter → set permissions immediately**, per 6.5.

## What this runbook cannot check for you

Verified only against a real Pocket ID and a real node — first-run unknowns, not
things that work.

- **The `groups` claim's shape.** BookStack reads `OIDC_GROUPS_CLAIM=groups` and
  expects an array of names; if group sync silently does nothing, dump the claims
  with `OIDC_DUMP_USER_DETAILS=true` and see what Pocket ID actually sent.
- **Egress to the issuer.** BookStack fetches
  `<issuer>/.well-known/openid-configuration` from inside its own pod, and the
  egress rule allowing it is a CIDR of the **Pangolin edge, not of roque**: the pod
  resolves `auth.struble.app` through public DNS, so the request leaves the cluster
  for the edge and tunnels back. An egress list holding only the private segment
  drops it while every pod still reports Ready.
  The `wiki-oidc-egress` CronJob in this chart now makes that request from this
  namespace every 30 minutes and alerts through the same path BookStack uses, so
  the CIDR going stale is a page rather than a silent outage. What it cannot tell
  you: it has never run yet, so its own first pass is unverified; a green probe is
  evidence about the route, not about the `iss` string matching or the claim
  arriving; and once the CoreDNS split-horizon work lands (canonical-URLs phase 0)
  the in-cluster answer and the edge address may legitimately diverge, which is the
  point at which the `/32` can go away.
- **The LAN route.** `wiki.mjolnir` needs a record in LAN DNS pointing at the node
  (10.0.0.4); the `.mjolnir` zone is per-host rather than a wildcard, and a missing
  record does not announce itself — a correct Ingress and a correct NetworkPolicy
  still give a browser that never receives an answer. DNS first, then the policy,
  then the app:

  ```
  dig +short A wiki.mjolnir @10.0.0.1
  ```

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
- **The tunnel.** Nothing in this directory publishes `wiki.struble.app`; until the
  Pangolin connector lands the other path is `kubectl -n wiki port-forward
  svc/wiki-bookstack 8080:80`. The connector PR carries one wiki-side acceptance
  item beyond reachability: `bookstack.trustedProxies` (rendered as `APP_PROXIES`)
  has to name the connector's network, not only the pod CIDR the LAN Ingress
  arrives from. Left short, BookStack trusts no proxy for that source, so login
  throttling and the audit log key on the connector's own address — one person's
  failed logins lock out the whole household, and every audit line records the same
  source IP. Pocket ID sets `TRUST_PROXY` for the same reason.
