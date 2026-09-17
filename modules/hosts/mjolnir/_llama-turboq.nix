{
  lib,
  fetchurl,
  cmake,
  ninja,
  pkg-config,
  openssl,
  autoAddDriverRunpath,
  cudaPackages,
}:
# Indras-Mirror/llama.cpp-turboq-mtp (master = Qwen35/Qwen3.8-27B build):
# sliding-window attention (SWA) hybrid, fused TBQ4/TBQ3 4-bit KV flash
# attention, custom MTP. sm_75 (Titan RTX) via nixpkgs cudaPackages.
# Purpose: keep 27B decode fast at deep context (their 4090 numbers: ~70 t/s
# @62K with SWA window 4096 + 8 global layers, MTP acceptance 1.00).
cudaPackages.backendStdenv.mkDerivation (finalAttrs: {
  pname = "llama-cpp-turboq";
  version = "0.3.0-8f2b243";

  # fetchurl on the codeload URL: the api.github.com tarball endpoint is
  # non-deterministic (same commit, different hashes across fetches — hit on
  # 2026-09-11). codeload verified stable from both mac and mjolnir.
  src = fetchurl {
    url = "https://github.com/Indras-Mirror/llama.cpp-turboq-mtp/archive/8f2b24374e44ed6ea2d62e1292c9e3220d557616.tar.gz"; # pragma: allowlist secret
    hash = "sha256-sPTNcd+VMikWEOT1tEhmuJ7p1e8AXtOB5IkMSg96Z7A="; # pragma: allowlist secret
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

  cmakeFlags = [
    (lib.cmakeBool "GGML_NATIVE" true)
    (lib.cmakeBool "GGML_CUDA" true)
    (lib.cmakeBool "GGML_CUDA_FA" true)
    (lib.cmakeBool "GGML_CUDA_FA_ALL_QUANTS" true)
    (lib.cmakeBool "GGML_CUDA_FORCE_MMQ" true)
    (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" "75")
    (lib.cmakeBool "LLAMA_BUILD_SERVER" true)
    (lib.cmakeBool "LLAMA_BUILD_EXAMPLES" false)
    (lib.cmakeBool "LLAMA_BUILD_TESTS" false)
    (lib.cmakeBool "LLAMA_BUILD_UI" false)
    (lib.cmakeBool "LLAMA_OPENSSL" true)
    (lib.cmakeBool "BUILD_SHARED_LIBS" true)
  ];

  meta = {
    description = "llama.cpp fork: Qwen35 SWA + fused TBQ4 KV FA + MTP, sm_75";
    homepage = "https://github.com/Indras-Mirror/llama.cpp-turboq-mtp";
    license = lib.licenses.mit;
    mainProgram = "llama-server";
    platforms = [ "x86_64-linux" ];
  };
})
