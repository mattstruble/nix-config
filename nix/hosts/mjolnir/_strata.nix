{
  lib,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  openssl,
  autoAddDriverRunpath,
  cudaPackages,
  python3,
  python3Packages,
}:
# Strata engine (Niko1221/Strata) for Qwen3.8-Flash-Next, sm_75 (Titan RTX).
# A self-contained bundle: the compiled CUDA engine + a Python env with the
# server's deps + the server source (serve/, setup.py, data/expert-profile.bin)
# + the entrypoint. Layout mirrors the docker image so docker-entrypoint.sh
# works unchanged (it cds to the bundle and runs .venv/bin/python setup.py).
#
# The engine is built exactly the way setup.py builds it (cmake, CUDA, the
# pinned llama.cpp for ggml). The Python env is python3.withPackages (no venv
# symlinks to /usr/bin/python3, so it is portable into the pod via the
# nix-store-pvc mount — unlike the NixOS-host .venv, which is store-coupled).
#
# The model + pack + MTP + config live on the models PVC (/data), NOT here.
let
  # the server's Python: the stdlib + the runtime deps, no venv. A let binding
  # (not a mkDerivation key) so ${pythonEnv} is in scope for the installPhase.
  pythonEnv = python3.withPackages (ps: with ps; [
    numpy
    jinja2
    regex
    pyyaml
    tqdm
    requests
    pillow
    psutil
  ]);
  # ggml comes from llama.cpp at the commit setup.py pins (setup.py:166). A let
  # binding so ${llamaCpp} is in scope for the buildPhase (STRATA_GGML_DIR).
  llamaCpp = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = "3cf03257f219afbe7334045ff7c6a06ac68c627d"; # pragma: allowlist secret (git commit id, not a secret)
    hash = "sha256-SRGoXa+4ACBCB3eaG9XFYhMN1i0FyPEy9Rrer+dFGYI="; # pragma: allowlist secret
  };

in
# Checked against the nixpkgs CUDA guidance: it recommends __structuredAttrs for
# cudaPackages.mkDerivation, where the wrapper turns cudaFlags into per-arch
# compile invocations. This is a plain cmake + nvcc-as-a-tool build with no
# cudaFlags handling, so structured attrs would buy nothing - and flipping them
# changes the output path, which forces a full native sm_75 rebuild on mjolnir
# and a new pinned path in the values file for zero correctness gain. Not set on
# purpose. strictDeps is the same story: cmake resolves cuda_cudart/cccl out of
# buildInputs, so restricting the native env risks the configure step for no
# gain here either.
cudaPackages.backendStdenv.mkDerivation (finalAttrs: {
  pname = "strata";
  version = "0.1.40.3";

  src = fetchFromGitHub {
    owner = "Niko1221";
    repo = "Strata";
    rev = "d5ea7133741e67743c0e886bb426c0ce8d69cf6c"; # pragma: allowlist secret (v0.1.40.3 git commit id)
    hash = "sha256-DWjDxgvIkwNDGyl+bN/UOoAtPtKtveVQVTcNaOVvTOk="; # pragma: allowlist secret
  };

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    cudaPackages.cuda_nvcc
    autoAddDriverRunpath
  ];

  buildInputs = [
    cudaPackages.cccl
    cudaPackages.cuda_cudart
    cudaPackages.libcublas
    openssl
  ];

  # build the engine: the same cmake options setup.cmake_build uses (setup.py:3057),
  # with STRATA_GGML_DIR pointing at the pinned llama.cpp (so CMake add_subdirectory
  # the ggml source instead of FetchContent git-cloning it, which has no git).
  cmakeFlags = [
    "-DSTRATA_ENABLE_CUDA=ON"
    "-DSTRATA_BUILD_TESTS=OFF"
    "-DCMAKE_CUDA_ARCHITECTURES=75"
    "-DSTRATA_GGML_DIR=${llamaCpp}"
  ];

  # bundle: engine + python + server source + entrypoint, laid out like the
  # docker image (WORKDIR /opt/strata) so docker-entrypoint.sh is unchanged.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/.venv/bin $out/data
    install -m755 strata $out/bin/strata
    ln -s ${pythonEnv}/bin/python $out/.venv/bin/python
    cp -r $src/serve $out/serve
    cp -r $src/tools $out/tools
    cp $src/setup.py $out/setup.py
    cp $src/data/expert-profile.bin $out/data/expert-profile.bin
    # the nix bundle is read-only, so the entrypoint (which links the config into
    # the cwd) can't run in place. This wrapper copies the config + server source
    # The upstream container entrypoint, vendored UNMODIFIED. Byte-identical is
    # the point: it is what knows CONTEXT / VISION / KV / GPUS / LAYER_SPLIT /
    # LOW_RAM / GGUF_DIR / RESIDENT_BUDGET_GIB / KV_STREAMING / REINSTALL /
    # CONFIG. A fork of it silently freezes that surface at whatever knobs the
    # fork happens to read - the first bundle here read four of fifteen. Bump the
    # pin, get the new knobs, with no merge conflict to notice.
    cp $src/docker-entrypoint.sh $out/docker-entrypoint.sh
    chmod +x $out/docker-entrypoint.sh

    # The one thing upstream cannot assume: its image has a WRITABLE /opt/strata
    # and this bundle is read-only. Stage what it needs writable, then hand over -
    # still without editing it.
    #
    #   /opt/strata   upstream does `cd /opt/strata` and runs `.venv/bin/python
    #                 setup.py`. Symlinked to the bundle, not copied: serve/ and
    #                 tools/ are only ever read.
    #   $CONFIGDIR    a REAL file, because setup.py rewrites the config it starts
    #                 from and both the ConfigMap and PVC copies are read-only.
    #                 Upstream's CONFIG branch symlinks it into /opt/strata, so a
    #                 rewrite lands here instead of failing on the read-only
    #                 mount. Fixed path, not a per-start timestamp: a timestamped
    #                 dir can never be reclaimed by the start that follows it.
    #
    # STRATA_EXECV=1 is set by the POD, not here. Upstream execs setup.py, which
    # leaves setup.py as PID 1 with no SIGTERM handler, so every rollout SIGKILLs
    # the engine mid-generation after burning the full termination grace. Opting
    # in from the pod spec keeps that dependency visible where the grace period
    # is set.
    cat > $out/bin/strata-pod-entrypoint <<'WRAPPER'
#!/bin/sh
set -e
BUNDLE="''${STRATA_BUNDLE:?STRATA_BUNDLE must point at the strata bundle}"
WORK="''${STRATA_WORK:-/opt/strata}"   # overridable so the staging logic is testable off-host
# /dev/shm, not /tmp: the API key is written into the config copy below, and
    # /dev/shm is the tmpfs the pod already mounts.
    CONFIGDIR="''${STRATA_CONFIG_DIR:-/dev/shm/strata}"
mkdir -p "$WORK"
for f in .venv serve tools data; do
  [ -e "$BUNDLE/$f" ] && ln -sfn "$BUNDLE/$f" "$WORK/$f"
done
# setup.py must be a REAL file, not a symlink: it computes ROOT via
# Path(__file__).resolve().parent (setup.py:61), and resolve() follows a symlink
# back into the read-only bundle - where there is no strata-*.json - so
# installed_configs() finds nothing and setup.py drops into the interactive setup
# pass ("Which model?"), which dies on EOF. A copy keeps ROOT at $WORK, where the
# config link the entrypoint creates is found.
cp "$BUNDLE/setup.py" "$WORK/setup.py"
# the same tag upstream derives from FAMILY/MODEL (family qwen has no prefix)
FAMILY="''${FAMILY:-qwen}"
MODEL="''${MODEL:-IQ2_XS}"
case "$FAMILY" in qwen) prefix="" ;; *) prefix="''${FAMILY}-" ;; esac
tag="''${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"
cfg="''${STRATA_DATA:-/data}/config/strata-$tag.json"
[ -f "$cfg" ] || { echo "config $cfg not found" >&2; exit 1; }
rm -rf "$CONFIGDIR"
mkdir -p "$CONFIGDIR"
cp "$cfg" "$CONFIGDIR/strata-$tag.json"
export CONFIG="$CONFIGDIR/strata-$tag.json"

# The key goes INTO the config, not onto the command line. Upstream's entrypoint
# passes --api-key only on the setup pass; on the serve pass it passes just
# --port/--gpus/--gpu/--layer-split, and setup.py keeps cfg["api_key"] unless the
# CLI supplies one (setup.py:5416) - so an empty config api_key means the server
# starts with no auth at all (setup.py:3989, and it says so at :5472). The
# rendered config is deliberately empty because the key lives in the
# litellm-keys Secret, so the Secret has to reach the copy that actually starts.
if [ -n "''${API_KEY:-}" ]; then
  "$BUNDLE/.venv/bin/python" - "$CONFIG" "$API_KEY" <<'KEYPY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
cfg["api_key"] = key
with open(path, "w") as f:
    json.dump(cfg, f, indent=1)
KEYPY
fi
exec "$BUNDLE/docker-entrypoint.sh" "$@"
WRAPPER
    chmod +x $out/bin/strata-pod-entrypoint
    runHook postInstall
  '';

  meta = {
    description = "Strata engine: Qwen3.8-Flash-Next on sm_75 (CUDA), engine + server bundle";
    homepage = "https://github.com/Niko1221/Strata";
    license = lib.licenses.mit;
    mainProgram = "strata";
    platforms = [ "x86_64-linux" ];
  };
})
