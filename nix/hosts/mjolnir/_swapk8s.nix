{
  lib,
  pkgs,
  fetchFromGitHub,
  buildGo127Module,
  buildGoModule,
}:
# The swap head-end: llama-swap (the model router, queue and TTL engine) plus
# swapk8s (this repo's shim, which gives it Kubernetes lifecycle control over
# model Deployments the helm chart owns).
#
# Built from source rather than pinned as an OCI image, for three reasons. The
# upstream `unified-*` images ship llama-server, whisper, audio.cpp, sd.cpp and a
# vllm wrapper — backends this cluster's chart owns, so they would be dead weight
# in a pod that needs one Go binary. Neither binary exists in an image at all
# without building one, and swapk8s has to be in there with llama-swap. And a
# store path linked through the render is this repo's rule for anything a
# manifest mounts (see services.k3s.aiChart.strataBundle for the argument): a GC
# cannot remove a model out from under a running pod.
#
# Built natively on mjolnir, like the strata bundle: it is an x86_64-linux
# derivation and the local machine is aarch64-darwin.
let
  llamaSwap = buildGo127Module rec {
    pname = "llama-swap";
    # Tag v264. Pinned to a commit because a tag can be re-pointed and a store
    # path cannot be re-verified after the fact.
    version = "264";

    src = fetchFromGitHub {
      owner = "mostlygeek";
      repo = "llama-swap";
      rev = "a025e0373addc2cd76e77a5064d60c517f05dcf8"; # pragma: allowlist secret (v264 git commit id, not a secret)
      hash = "sha256-GwMa1V1zOWyT3pLPiOIlarqF0X0Vyeq7tmnK9mUJfvI="; # pragma: allowlist secret
    };

    # go.mod says `go 1.27.1` and nixpkgs' default Go is 1.26.8. Upstream's own
    # toolchain would be fetched by GOTOOLCHAIN, which needs network the build
    # sandbox does not have, so the 1.27 builder is explicit rather than
    # incidental.
    #
    # Only the root package: cmd/ carries kubeswap, wol-proxy, vllm-wrapper and
    # test helpers, none of which run in this pod.
    subPackages = [ "." ];

    # internal/server/embed.go does `go:embed all:ui_dist`, and ui_dist is
    # gitignored upstream (built by `make ui`, i.e. npm + vite). A source build
    # therefore fails on a missing directory unless something stands in for it.
    # The web UI is not served from this pod — the head-end is reached through
    # LiteLLM, and the metrics endpoint is what anyone watches — so a placeholder
    # is the honest fix and it keeps Node out of this configuration. If the UI is
    # ever wanted, the fix is a ui build step, not a different placeholder.
    postPatch = ''
      mkdir -p internal/server/ui_dist
      cat > internal/server/ui_dist/index.html <<'HTML'
      <!doctype html><title>llama-swap UI not built</title>
      <p>This bundle is built by nix without the npm UI step. Use the API.</p>
      HTML
    '';

    # Pure Go: sqlite comes from modernc.org/sqlite, not mattn/go-sqlite3, so no
    # C toolchain is needed. Set via preBuild rather than as a derivation
    # attribute - buildGoModule already puts CGO_ENABLED in env, and passing it
    # twice is a hard evaluation error, not an override.
    preBuild = "export CGO_ENABLED=0";
    proxyVendor = true;
    vendorHash = "sha256-pihd/GVw3GqZTwBgb8gYo2zyLpE4HqKI0xb//tojMyo="; # pragma: allowlist secret

    # Upstream's tests shell out to llama-server and bind ports.
    doCheck = false;

    ldflags = [
      "-s"
      "-w"
      "-X main.Build=${version}"
    ];

    meta = {
      description = "llama-swap: OpenAI-compatible proxy that swaps llama.cpp-compatible models on demand";
      homepage = "https://github.com/mostlygeek/llama-swap";
      license = lib.licenses.mit;
      mainProgram = "llama-swap";
      platforms = [ "x86_64-linux" ];
    };
  };

  swapk8s = buildGoModule rec {
    pname = "swapk8s";
    version = "0.1.0";

    src = ../../../src/swapk8s;

    subPackages = [ "." ];
    preBuild = "export CGO_ENABLED=0";
    # Stdlib only, on purpose: there is nothing to vendor, and that is what lets
    # this build with no module proxy and no vendorHash.
    vendorHash = null;
    # The roster parser and the spec normaliser are the two places where a silent
    # wrong answer means "reap the fleet" or "a chart apply resized a running
    # model". They are tested in the build.
    doCheck = true;

    meta = {
      description = "llama-swap lifecycle shim for chart-owned model Deployments";
      license = lib.licenses.mit;
      mainProgram = "swapk8s";
      platforms = lib.platforms.all;
    };
  };
in
# One store path, two binaries: the pod mounts this and calls
# /bin/llama-swap, whose model `cmd` entries call /bin/swapk8s.
pkgs.symlinkJoin {
  name = "swap-head-end-${swapk8s.version}";
  paths = [
    llamaSwap
    swapk8s
  ];
}
