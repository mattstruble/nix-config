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
    # to a writable dir (/tmp/strata) and runs setup.py from there (the engine +
    # python stay in the read-only bundle; the config's exe/cwd/expert-profile
    # already point at the bundle's paths). The ''${} escapes keep the shell
    # variables literal (not interpolated by nix).
    cat > $out/docker-entrypoint.sh <<'ENTRYPOINT'
#!/bin/sh
set -e
BUNDLE="''${STRATA_BUNDLE:-/opt/strata}"
WORK=/tmp/strata-$(date +%s)
export HOME="$WORK"
STRATA_DATA="''${STRATA_DATA:-/data}"
FAMILY="''${FAMILY:-qwen}"
MODEL="''${MODEL:-IQ2_XS}"
PORT="''${PORT:-8080}"
GPU="''${GPU:-}"
case "$FAMILY" in qwen) prefix="" ;; *) prefix="''${FAMILY}-" ;; esac
tag="''${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"
cfg="$STRATA_DATA/config/strata-$tag.json"
[ -f "$cfg" ] || { echo "config $cfg not found" >&2; exit 1; }
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$cfg" "$WORK/strata-$tag.json"
# tools/: serve/server.py sys.path-inserts <ROOT>/tools and imports
# strata_tokenizer from there (pure Python: stdlib + regex, both in the
# bundle's python env) - without it the server dies on
# ModuleNotFoundError: strata_tokenizer
cp -r "$BUNDLE/serve" "$WORK/serve"
cp -r "$BUNDLE/tools" "$WORK/tools"
cp "$BUNDLE/setup.py" "$WORK/setup.py"
cd "$WORK"
# STRATA_EXECV=1 (like the upstream Docker image): setup.py os.execv's into
# serve/server.py, making the SERVER PID 1 - without it PID 1 is setup.py (no
# SIGTERM handler), so every rollout/drain SIGKILLs the engine mid-generation
# after burning the full termination grace period.
export STRATA_EXECV=1
set -- --port "$PORT"
if [ -n "$GPU" ]; then set -- "$@" --gpu "$GPU"; fi
# the API key comes from the pod's litellm-keys Secret (chart env API_KEY),
# NOT the config json (whose api_key is a prototype-era placeholder): setup.py
# line ~5416 lets a CLI --api-key override the config, and setup.py reads
# STRATA_API_KEY as the --api-key default - but neither is how the chart wires
# it, so forward the API_KEY env explicitly (the upstream image does the same).
if [ -n "$API_KEY" ]; then set -- "$@" --api-key "$API_KEY"; fi
exec "$BUNDLE/.venv/bin/python" setup.py "$@"
ENTRYPOINT
    chmod +x $out/docker-entrypoint.sh
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
