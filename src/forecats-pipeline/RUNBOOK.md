# forecats — render input runbook

The nightly render is one child process, inside the pod that holds the card. It
reads the weights and the reference photos from mounted volumes and the diffusion
CLI from `PATH`, and it opens no connection to another machine — so a render pod
needs no hostname, no key and no SSH agent, and mounting credentials into one
would be a bug rather than a convenience.

## Where each input comes from

| Input | Read from | Placed by |
| --- | --- | --- |
| The four weight files | `/var/lib/llama-models/h3image` | `forecats-stage-inputs weights`, onto the `forecats-weights` volume |
| One reference photo per pet | `/var/lib/forecats/photos` | `forecats-stage-inputs photos`, onto the `forecats-photos` volume |
| `sd-cli` | `PATH`, which `--sd-cli-binary` defaults to | the render host, which names a CUDA build with `--sd-cli-binary` or puts one first on `PATH`; `packages.forecats-pipeline` carries none |

A volume's mount point is the path the render reads, in the pod and on the host
that fills it. `nix/services/k3s.nix` declares it once, and the host directory it
creates, the local volume over it and the two variables the pipeline wrapper
exports are all read from that one entry — the render holds no path of its own,
so moving a volume is a change to the declaration and to nothing else. A render
aimed at a directory nothing mounts refuses rather than drawing from an empty one.

The two input volumes are read-only in the pod and root-owned on the host,
because nothing in the cluster writes them. The panels volume is the writable
one, owned by uid 982 — the uid the render pod runs as, since the policy that
keeps these pods non-root also forbids the `chown` init container that would
otherwise set that ownership.

## Why a claim and not a host path

The `forecats` namespace carries `pod-security.kubernetes.io/enforce=restricted`,
and restricted refuses a pod that names a host path. `forecats-weights`,
`forecats-photos` and `forecats-panels` are what a restricted pod is allowed
instead: claims pre-bound to local volumes over those same host directories.
`nix/services/k3s.nix` owns the claims, the volumes and the directories; this
file only says what a pod mounts them at.

## Place the weights

17.9 GB, once, and again after any run that stopped halfway.

1. Write the four digests to a manifest. Each value is the sha256 the model hub
   publishes for that file — the LFS oid on the file's page — and not the hash of
   whatever is in the download directory, which proves only that a copy matches
   itself.

   ```json
   {
     "minimax_h3_image_pruned-Q3_K_M.gguf": "<64 hex>",
     "vae_diffusion_pytorch_model.safetensors": "<64 hex>",
     "p-h3-image_text_encoder_int8_convrot.safetensors": "<64 hex>",
     "p-h3-image_tokenizer.json": "<64 hex>"
   }
   ```

2. Place them.

   ```sh
   forecats-stage-inputs weights --from ~/Downloads/h3image --manifest /tmp/h3image.json
   ```

   Check: one line per file with its `sha256=`, and a last line reading
   `4 files verified at /var/lib/llama-models/h3image, N copied`. Nothing is
   copied until every source has been digested, so a refusal — a file whose bytes
   are not the manifest's, or a manifest that leaves one of the four out — leaves
   the volume as it found it and names the file. A render that started and then
   could not find the fourth file would already have paid for the model load.

3. Run the same command again.

   Check: `0 copied` and no file rewritten. That is the retry, and it is what
   makes the step repeatable after a full volume stopped a copy halfway.

`--to` names another directory: the weights a render was told to read elsewhere,
or a second set to compare. Without it the directory comes from
`FORECATS_MODEL_DIRECTORY`, which the wrapper exports from the declaration; run
straight from a shell that has never seen the wrapper, the command refuses and
names that variable.

## Place the reference photos

1. Put the photos the household file names into one directory, under the names
   the file gives them. The file names each photo absolutely, inside the directory
   being filled: the render opens the path as written, wherever it runs.

2. Place them.

   ```sh
   forecats-stage-inputs photos --from ~/Pictures/cats \
     --household-file src/forecats-pipeline/household.yaml
   ```

   Check: one line per photo. A photo the household file names that is not in
   `--from` refuses the run and names it, and so does a `--to` the household file
   does not name — photos staged where the render does not look are photos that do
   not exist.

A photo that is missing at render time is refused there too, before the CLI
starts. With the file absent the model draws the animal from the words alone and
exits 0, so the panel shows a cat that does not live here and nothing downstream
can tell.

## What a render pod has to provide

- The three claims, mounted at the three paths above, the two inputs read-only.
  The wrapper exports the two input mount points, so a pod that mounts one of them
  somewhere else names that path with `FORECATS_MODEL_DIRECTORY` and
  `FORECATS_PHOTO_DIRECTORY`.
- `NVIDIA_VISIBLE_DEVICES` naming the card the job holds. The render inherits it
  rather than naming a card of its own; `--render-gpu` is for a host with no such
  pin, where GPU0 is the owner's live session.
- `FORECATS_CALENDAR_FEEDS`, and the model endpoint or key if an occasion is to
  be asked about, from the namespace's Secret.
- `forecats-pipeline` from `packages.forecats-pipeline` as the command, and the
  diffusion CLI itself. The package closure carries no `sd-cli`: the only nixpkgs
  build that renders on a card does not evaluate on every host the package is
  built for, and the build that does is the portable one. Name a CUDA build with
  `--sd-cli-binary` or put one first on `PATH`, and it has to be a store path the
  host holds: a binary outside the store loses its glibc to the next garbage
  collection. A render whose log says `CUDA driver is a stub library` found a CPU
  build anyway, and the renderer refuses that render rather than publishing the
  picture it drew.
- Nothing else. No host, no key, no agent.
