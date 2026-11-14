# k8s/

Helm charts and cluster manifests for the homelab k3s cluster (mjolnir).

## Layout

```
k8s/
├── apps/<domain>/     # one directory per app domain; a helm chart where we own one
│   ├── ai/            #   LLM fleet + LiteLLM gateway
│   │   ├── templates/
│   │   ├── values.yaml        # shared values (gateway, chat template)
│   │   └── values/<model>.yaml  # one file per model; maps merge across -f
│   ├── monitoring/    #   NOT a chart: values for the upstream monitoring charts
│   │   ├── values/<chart>.yaml  #   (kube-prometheus-stack, loki, alloy,
│   │   ├── dashboards/          #   dcgm-exporter), plus the Grafana dashboards
│   │   └── llama-metrics.md     #   metrics contract the dashboards assume
│   └── wiki/          #   BookStack + MariaDB; permissions are set in the UI
│       ├── templates/
│       ├── values.yaml        # images, resources, OIDC, storage
│       ├── SECRETS.md         # the Secret this chart references and never creates
│       └── RUNBOOK.md         # activation, and the one-time UI configuration
└── manifests/         # cluster-level yaml auto-applied by k3s (nix/services/k3s.nix)
```

### Adding an app

A directory under `apps/<domain>/` that carries a `Chart.yaml` is the small part:
`just k8s-render` picks it up the moment it lands. `./scripts/check-app-wiring.sh`
(the `k8s-app-wiring` job) asks the three places that name apps by hand whether each
names the chart directory — the nix render derivation, the PR preview render step,
and Renovate's `managerFilePatterns` — so forgetting one fails the PR. These points
are not in that check, and each is silent when missing:

- `system.build.<app>ChartRendered` in `nix/services/k3s.nix`. Without it the render
  derivation is never in the system closure, and the failure lands on the cluster at
  switch time.
- The `sops.secrets."services/<app>/*"` declarations, their `.sops.yaml` path rule,
  and the sops file itself. A secret no one declares is simply absent when the pod
  reads it.
- The apply oneshot in `nix/services/k3s.nix`: it creates the Secret the chart
  references and must never define, applies the rendered manifest, and labels it
  into the app's namespace.
- `services.k3s.manifests.<app>-pvs`, and the host directories those PVs bind to in
  `tmpfiles.rules`, for an app that needs local storage.
- The per-app lists in `.github/workflows/renovate-config-check.yml` and
  `.github/workflows/chart-image-digests.yml`.

## Keeping images current

`renovate.json` reads the chart values files with a regex manager, so a new model
file is covered the moment it lands — no annotation to remember, as long as the key
ends in `image:`/`Image:` and the file is listed in `managerFilePatterns`. Renovate
was run against this repo to confirm it extracts all eleven pins across both apps; a
literal `image:` pattern matches one of them, which is the trap.

- **Weekly, grouped.** Control-plane images (`values.yaml`) and model serving images
  (`values/*.yaml`) are separate PRs, because "bump the gateway" and "bump what three
  models serve" are different decisions.
- **Auto-merge is patch-only**, and never for `values/*.yaml`, never for LiteLLM (it
  holds the master key), never for a digest-only bump (content moved under a version
  that looks unchanged). Everything else waits for a human.
- **llama.cpp is versioned by build number**, not by Docker versioning: upstream ships
  each CUDA build as its own tag (`server-cuda12-b11151`, 858 of them), which Docker
  versioning cannot order — without the regex versioning Renovate offers no upgrade at
  all and llama.cpp, the thing parsing every model file, never gets a security bump.
- **`.github/workflows/chart-image-digests.yml`** resolves every pinned tag at its
  registry and requires the digest to match. It runs on a schedule as well as on PRs,
  because the two ways a pin rots — a per-architecture digest pasted in place of the
  index digest, or upstream re-pushing a tag — produce no commit here and surface as a
  pod that will not pull.

**Vendored Helm charts** (`nix/services/k3s.nix`) are release tarballs fetched by
`fetchurl`, so they carry a second pin that update automation cannot see: the
`sha256`. Renovate's nix manager only understands flake inputs, so it bumps the URL and
leaves the hash behind - `chart-hash-fixup.yml` recomputes it and pushes the correction to
the Renovate branch, running its script from the base revision rather than the pull request.
`./scripts/chart-hashes.sh` does the checking and the repairing; run it with `--check` to
audit. It only repairs pins whose URL actually moved, because a pin whose URL did not move
but whose hash disagrees is a re-pushed release asset, and quietly adopting those bytes is
what the pin exists to prevent. Those stay red for a human.

Renovate is inert until the GitHub App is installed on the repo with this repo's
access; the config validates and extracts without it, but nothing files a PR.

## Deploy

- `just deploy mjolnir` — nix build renders the chart and the ai-chart-apply
  oneshot `kubectl apply`s it after k3s is up (one generation covers host
  config + cluster manifests).
- `just k8s-render` — render every app chart to stdout. There is no
  render-and-apply recipe; a manual apply is `helm template … | ssh mjolnir
  kubectl apply -f -`, and the next `just deploy` reconciles whatever it did.
- PRs touching `k8s/` get a rendered-manifest diff comment (`.github/workflows/k8s-manifest-diff.yml`).

## Conventions

- **Pin every image as `repository:tag@digest`** — resolve with `./scripts/resolve-digest.sh <image:tag>`. The digest is what runs; the tag is what update automation reads, so a digest-only reference silently opts an image out of security bumps. The digest must be the index digest the runtime resolves, not a per-architecture manifest; the script refuses anything else.
- **Every image resolves from values, never from a template literal.** A string inside a template is invisible to update automation, so the chart's own base images are `gateway.toolsImage` (head-end init containers, the llama-swap container, the log-exporter sidecar) and `gateway.postgresImage`, and the templates read them through `required` - a missing value fails the render instead of emitting an empty image field.
- **One values file per model** under `values/`; `enable: false` = no pod, no route.
- **GPU pinning:** `gpu: "0"|"1"` → `NVIDIA_VISIBLE_DEVICES` + `runtimeClassName: nvidia` (CDI mode). Never two models on one GPU.
- **PSS restricted** is the target for every pod: runAsNonRoot, drop ALL, seccomp, no SA token, readOnlyRootFilesystem (container-level — k3s drops the pod-level field). It is not what every namespace is labelled: `wiki` is `enforce=baseline`, because the BookStack image is an s6-overlay image that cannot start below root and must write inside a directory it has just chowned — that container sets `runAsNonRoot: false` and `readOnlyRootFilesystem: false` on purpose, and the header of `k8s/apps/wiki/templates/bookstack-deployment.yaml` records what was measured, what the five added capabilities buy back, and what bounds the exception. Read that header before copying this convention into the next chart. (`gpu` and `monitoring` are labelled `enforce=privileged` for their DaemonSets; the labels are applied in `nix/services/k3s.nix`.)
- **Resource limits on every pod.**
- Fork-binary models (`nixBinary: true`) hardcode a `/nix/store/<hash>` path — update it when the fork is rebuilt.
- `k8s/manifests/` is auto-applied by k3s at node start; keep it node-agnostic (per-node files go in `manifests/<node>/` if that day comes).
- **What a document may contain** is written once, in [AGENTS.md](../AGENTS.md), which governs this file too.
