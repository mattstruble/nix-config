# Research: autoDeployCharts vs runCommand for the local ai chart

**Ticket:** nix-config-h1j.1
**Question:** Does `services.k3s.autoDeployCharts` support deploying a LOCAL in-repo helm chart with multiple merged values files? If not, what is the canonical nix pattern?

**Verdict: KEEP the current `pkgs.runCommand` + `system.activationScripts` approach.**
The `autoDeployCharts` option is designed for remote-repository or pre-packaged `.tgz` charts with a single values source. Adapting it to our local unpacked chart + 9 merged values files + `.Files.Get` local dependency would add complexity with no operational benefit.

---

## 1. What `services.k3s.autoDeployCharts.<name>` offers

Source: [nixpkgs nixos/modules/services/cluster/k3s/default.nix @ d07ebbab](https://github.com/NixOS/nixpkgs/blob/d07ebbab9bcf9726e224fd2ef71daf63fd16098b/nixos/modules/services/cluster/k3s/default.nix) (merged via PR [#374017](https://github.com/NixOS/nixpkgs/pull/374017)).

Per-chart options:

| Option | Type | Notes |
|--------|------|-------|
| `enable` | bool | Default true. Setting false does **not** uninstall existing releases. |
| `repo` | nonEmptyStr | Helm repository URL (e.g. `https://kubernetes.github.io/ingress-nginx`). |
| `name` | nonEmptyStr | Chart name in the repo. |
| `version` | nonEmptyStr | Chart version in the repo. |
| `hash` | str | SRI hash for fetch-verified `helm pull`. |
| `package` | `path \| package` | **Pre-packaged `.tgz`**. Overrides `repo`/`name`/`version`/`hash`. |
| `targetNamespace` | str | Default `"default"`. |
| `createNamespace` | bool | Default false. |
| `values` | `path \| attrs` | **Single** values source: either a path to one YAML file or a Nix attrset (converted to inline JSON). |
| `extraDeploy` | listOf (path \| attrs) | Extra raw manifests appended after the HelmChart CR in the same YAML doc. |
| `extraFieldDefinitions` | attrs | Merged into the `HelmChart` CR spec (e.g. `bootstrap`, `jobImage`). |

**There is no `valuesFiles` option and no support for a local unpacked chart directory.**

---

## 2. Can `repo` or `package` point to a local unpacked chart?

**No.**

- `repo` is fed into `helm repo add <repo> <repo-url>` inside a `fetchHelm` derivation. It must be a valid Helm repository URL ([source](https://github.com/NixOS/nixpkgs/blob/d07ebbab9bcf9726e224fd2ef71daf63fd16098b/nixos/modules/services/cluster/k3s/default.nix#L69-L85)).
- `package` must be a **packaged `.tgz` archive** (type is `either path package`). The module’s `mkHelmChartCR` hardcodes the `chart` field in the generated `HelmChart` CR to:
  ```nix
  chart = "https://%{KUBERNETES_API}%/static/charts/${name}.tgz";
  ```
  ([source](https://github.com/NixOS/nixpkgs/blob/d07ebbab9bcf9726e224fd2ef71daf63fd16098b/nixos/modules/services/cluster/k3s/default.nix#L118))

The `.tgz` is placed on disk via `services.k3s.charts` (linked to `/var/lib/rancher/k3s/server/static/charts/`) and served by the k3s API server. The Helm controller (klipper-helm) detects the `https://` prefix and treats it as a direct chart archive URL, skipping repo init ([klipper-helm entry](https://github.com/k3s-io/klipper-helm/blob/master/entry)).

**`file://`, local directories, or OCI local refs are not supported by this NixOS option.**

---

## 3. Can it merge multiple values files?

**No.**

- `values` accepts **exactly one** path or attrset. There is no list-of-paths type.
- The k3s helm-controller *does* support multiple values projections (via `ValuesSecrets` and projected volumes), but the NixOS `autoDeployCharts` module does not expose that interface.
- Helm’s native deep-merge semantics across multiple `-f` files would have to be replicated manually in Nix (parse YAML → attrsets → `lib.recursiveUpdate` or similar), then fed as a single attrset to `values`. This is possible but fragile and loses the clarity of per-model values files.

Our current chart uses:
```bash
helm template ai k8s/apps/ai \
  -f k8s/apps/ai/values.yaml \
  -f k8s/apps/ai/values/gemma-4-26b-a4b.yaml \
  -f k8s/apps/ai/values/qwen3-8-27b.yaml \
  ...  # 8 per-model files total
```
That is not expressible in `autoDeployCharts` without pre-merging.

---

## 4. Does it handle a chart referencing a local file (`.jinja` ConfigMap source)?

**Only if the chart is pre-packaged as a `.tgz` containing the file.**

Our `templates/chat-template-configmap.yaml` uses:
```yaml
{{ .Files.Get "qwen3-chat-template.jinja" | indent 4 }}
```

Helm’s `.Files.Get` works inside a packaged chart archive as long as the file is in the chart root and not excluded by `.helmignore`. So:
- **With `autoDeployCharts`:** we would need a Nix derivation that runs `helm package k8s/apps/ai` to produce `ai-0.1.0.tgz`, then pass that as `package`. The `.jinja` would be bundled correctly.
- **With `runCommand`:** `helm template` on an unpacked directory already resolves `.Files.Get` relative to the chart root. This works today with no extra packaging step.

---

## 5. Canonical patterns evaluated

| Pattern | Feasible for this chart? | Effort / Risk |
|---------|--------------------------|---------------|
| **(a) Keep current `runCommand` + activation script** | ✅ Yes — works today, pods live. | Zero. Synchronous apply with retry loop. |
| **(b) Package as `.tgz` + `autoDeployCharts`** | ⚠️ Possible but awkward. Requires: (1) `helm package` derivation, (2) merge 9 YAML values files into one Nix attrset or single YAML, (3) accept async helm-controller lifecycle. | Medium. Adds indirection, loses per-model file clarity, and failures surface as k8s Job logs rather than NixOS activation errors. |
| **(c) Local helm/OCI registry** | ❌ Overkill. No benefit for a single-node k3s cluster. | High. |
| **(d) `services.k3s.charts` (older option)** | ⚠️ Only places `.tgz` in static dir. Does **not** deploy. You’d still need to write a raw `HelmChart` CR manifest by hand (via `services.k3s.manifests`). Effectively re-implementing `autoDeployCharts`. | Medium. No better than (a). |

---

## Recommendation

**Keep the current `pkgs.runCommand` render + `system.activationScripts` apply.**

Why:
1. **No impedance mismatch.** `helm template` natively supports unpacked local charts, multiple `-f` values files, and `.Files.Get`.
2. **Deterministic activation.** The manifest is rendered at Nix build time and applied during `nixos-rebuild switch` with a retry loop. If it fails, the deploy fails visibly.
3. **autoDeployCharts adds no value here.** It is optimized for “fetch a chart from the internet and let k3s manage it asynchronously.” Our use case is “render a local fleet chart with per-model overlays and apply it now.”
4. **The `.jinja` file and 8 values files stay first-class source files** instead of being hidden inside packaging/merging derivations.

If a second chart is added later that *is* fetched from a remote repo, `autoDeployCharts` should be used for **that** chart, while the local `ai` chart continues to use the render-then-apply pattern.

---

## Sources

- NixOS k3s module source (autoDeployCharts definition): https://github.com/NixOS/nixpkgs/blob/d07ebbab9bcf9726e224fd2ef71daf63fd16098b/nixos/modules/services/cluster/k3s/default.nix
- PR #374017 introducing autoDeployCharts: https://github.com/NixOS/nixpkgs/pull/374017
- k3s HelmChart CRD spec (`Chart` field semantics): https://github.com/k3s-io/helm-controller/blob/master/pkg/apis/helm.cattle.io/v1/types.go
- klipper-helm entry script (URL detection, values globbing): https://github.com/k3s-io/klipper-helm/blob/master/entry
- k3s helm-controller chart source resolution: https://github.com/k3s-io/helm-controller/blob/master/pkg/controllers/chart/chart.go
