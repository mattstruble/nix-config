# k8s/

Helm charts and cluster manifests for the homelab k3s cluster (mjolnir).

## Layout

```
k8s/
├── apps/<domain>/     # one helm chart per app domain (ai = LLM fleet + gateway)
│   └── ai/
│       ├── templates/
│       ├── values.yaml        # shared values (gateway, chat template)
│       └── values/<model>.yaml  # one file per model; maps merge across -f
└── manifests/         # cluster-level yaml auto-applied by k3s (nix/services/k3s.nix)
```

Adding an app: new dir under `apps/<domain>/` with its own chart. Adding a model
to the ai chart: one `values/<model>.yaml` — the chart renders a Deployment +
Service for it and adds it to the LiteLLM gateway model_list.

## Deploy

- `just deploy mjolnir` — nix build + post-activation hook renders the chart and
  `kubectl apply`s it (one generation covers host config + cluster manifests).
- `just k8s-deploy` — fast manual path: render + scp + apply, no nix build.
- PRs touching `k8s/` get a rendered-manifest diff comment (`.github/workflows/k8s-manifest-diff.yml`).

## Conventions

- **Pin every image as `repository:tag@digest`** — resolve with `./scripts/resolve-digest.sh <image:tag>`. The digest is what runs; the tag is what update automation reads, so a digest-only reference silently opts an image out of security bumps. The digest must be the index digest the runtime resolves, not a per-architecture manifest; the script refuses anything else.
- **Every image resolves from values, never from a template literal.** A string inside a template is invisible to update automation, so the chart's own base images are `gateway.toolsImage` (head-end init containers, the llama-swap container, the log-exporter sidecar) and `gateway.postgresImage`, and the templates read them through `required` - a missing value fails the render instead of emitting an empty image field.
- **One values file per model** under `values/`; `enable: false` = no pod, no route.
- **GPU pinning:** `gpu: "0"|"1"` → `NVIDIA_VISIBLE_DEVICES` + `runtimeClassName: nvidia` (CDI mode). Never two models on one GPU.
- **PSS restricted** on every pod: runAsNonRoot, drop ALL, seccomp, no SA token, readOnlyRootFilesystem (container-level — k3s drops the pod-level field).
- **Resource limits on every pod.**
- Fork-binary models (`nixBinary: true`) hardcode a `/nix/store/<hash>` path — update it when the fork is rebuilt.
- `k8s/manifests/` is auto-applied by k3s at node start; keep it node-agnostic (per-node files go in `manifests/<node>/` if that day comes).
