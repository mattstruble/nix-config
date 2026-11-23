# RUNBOOK — roborock (local_roborock_server on roque)

Everything the cluster cannot do for you, in the order it must happen. The
chart renders and applies fine with the sops values still at the `unset`
sentinel — the roborock pass skips loudly and nothing schedules — so steps 1
and 2 are independent and both must be done before the vacuum ever sees the
server.

## 1. UniFi: the DNS record and the firewall policies

One local DNS record and two firewall policies. The Integration API covers
neither fully, so these are hand-tuned; the UniFi IaC effort, if it ever
lands, inherits this list as its first acceptance test.

1. **Local DNS record.** UniFi Network → Settings → DNS (the *local DNS
   records* store, not per-client): `api-rr.local.struble.app` → roque's LAN
   IP. The name is two labels below the apex on purpose: the public
   `*.struble.app` wildcard at Cloudflare matches exactly one level, so this
   name resolves to NXDOMAIN from anywhere outside the LAN, and the existing
   wildcard needs no edit.
2. **Firewall policies.** Allow, from the deadzone VLAN and the HA zone,
   *to* roque, TCP on 555 and 8881. Nothing else: the vacuum needs no other
   path, and the WAN-less deadzone VLAN is what the onboarding wants —
   these robots query `8.8.8.8` directly until WAN is blocked, so the VLAN
   *is* the block.

**Verify** (from a client *on the deadzone VLAN*, which is the client that
must succeed):

```sh
dig +short api-rr.local.struble.app   # → roque's LAN IP
curl -skf -o /dev/null -w '%{http_code}\n' https://api-rr.local.struble.app:555/admin
```

`401` or `200` from curl means DNS + firewall + cluster + netpol all passed.
A timeout with a correct `dig` answer means the firewall policy or the
NetworkPolicy ingress list (`services.k3s.roborockIngressCidrs`) is missing
that VLAN's CIDR — they must agree, and this curl is the check that says so.

## 2. Secrets: fill `homelab-roborock-secrets.yaml`

Five sops values, all currently the literal string `unset`:

| key | what | generate with |
|---|---|---|
| `admin-password-hash` | dashboard login | the snippet below, option `admin` |
| `protocol-pin-hash` | app/HA login (the "code") | the snippet below, option `pin` |
| `session-secret` | admin session HMAC key | `openssl rand -base64 32` |
| `protocol-login-email` | the local login's "email" | any address you will type into LocalRock/HA |
| `cloudflare-token` | DNS-01 renewal | scoped: Zone → DNS → Edit, `struble.app` only |

The hashes are the app's own scheme (`pbkdf2_sha256$600000$<b64 salt>$<b64
digest>`, verified against upstream `security.py`):

```sh
python3 - <<'EOF'
import getpass, hashlib, base64, secrets
def h(pw):
    i, s = 600_000, secrets.token_bytes(16)
    d = hashlib.pbkdf2_hmac("sha256", pw.encode(), s, i)
    e = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
    return f"pbkdf2_sha256${i}${e(s)}${e(d)}"
print("admin-password-hash =", h(getpass.getpass("admin password: ")))
print("protocol-pin-hash  =", h(getpass.getpass("protocol PIN (6 digits): ")))
EOF
```

Put each value into
`nix/services/homelab/homelab-roborock-secrets.yaml`, re-encrypt
(`sops -e -i` applies the `.sops.yaml` rule — recipients are you and
mjolnir, **not roque**, the same shape as the wiki's file), commit, deploy.

The apply pass judges the sentinels the way the wiki's does: every value
still `unset` → the roborock pass skips loudly and the unit stays green; a
part-filled set is treated the same way. The pass that lands is the one that
creates the `roborock-config` Secret, and the pod starts against it.

## 3. Bring the vacuum in

The vacuum ships never-registered; onboarding pairs it straight to this
server. It never talks to Roborock's cloud at any step.

1. Join the vacuum to the **deadzone VLAN**'s Wi-Fi during its setup
   (app-less: it needs only the SSID).
2. Make sure the roborock pass deployed (pod Running on roque, secrets
   filled): `kubectl get pod -n roborock -o wide` — the node must be roque.
3. Run upstream onboarding from a second machine (the workstation;
   Python 3.11+ and `uv`), following the upstream `docs/onboarding.md`, with
   the admin dashboard at `https://api-rr.local.struble.app:555/admin` open
   for the cloud-import step. The cloud import is the one touchpoint with
   Roborock's cloud and it runs *from the server*, not the vacuum.
4. LocalRock: sign in with the protocol login email + 6-digit PIN.
5. Home Assistant: Settings → Devices & services → Add integration →
   Roborock → Region **Manual** → server URL
   `https://api-rr.local.struble.app:555` + the same email and PIN.
6. Verify a daily/weekly schedule fires from the server side (upstream flags
   schedules as experimental; the flag is worth one deliberate test before
   you trust it with a routine).

**If onboarding fails on certificate trust**: the pinned path is ZeroSSL.
Before switching anything, check upstream's tested-vacuums entry for the
Saros 10R at *your* firmware — `02.52.32` accepted ZeroSSL and Let's
Encrypt, but a newer firmware may not behave the same. Switching chains is a
config edit + re-render + re-onboard, which is why the vacuum is onboarded
once, deliberately, after the rest is verified.

## What this runbook cannot check for you

The UniFi state: the DNS record and the firewall policies exist only in the
controller's two stores, neither of which this repo can read. Section 1's
curl from a deadzone client is the only evidence the path works end to end,
and it is worth re-running after any UniFi firmware update that touches the
policy engine.
