{
  lib,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  openssl,
  autoAddDriverRunpath,
  cudaPackages,
}:
# Fork build of llama.cpp with qwen4exp (Qwen3.8-Flash-Next) support + MTP
# spec-decode + MoE expert residency (the `-ot "exps_cold=CPU"` backend split).
# Upstream llama.cpp has neither the residency patch nor MTP for qwen4exp.
# sm_75 (Titan RTX) only; CUDA 12.x via nixpkgs cudaPackages (nvcc 12.9).
cudaPackages.backendStdenv.mkDerivation (finalAttrs: {
  pname = "llama-cpp-qwen4exp";
  version = "0.3.0-0384f5c";

  src = fetchFromGitHub {
    owner = "mjungnickel18";
    repo = "llama.cpp";
    rev = "0384f5c660be6541307ee2e360d9567a3affd597";  # pragma: allowlist secret
    hash = "sha256-m0NWK92KeCmJLS9CWf2mrktciEIXKH7Qvo5IS+FFN4s=";  # pragma: allowlist secret
  };

  patches = [
    ../../../patches/llama-flashnext/0001-upstream-correctness-and-perf-fixes.patch
  ];

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
    (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" "75")
    (lib.cmakeBool "LLAMA_BUILD_SERVER" true)
    (lib.cmakeBool "LLAMA_BUILD_EXAMPLES" false)
    (lib.cmakeBool "LLAMA_BUILD_TESTS" true)
    (lib.cmakeBool "LLAMA_BUILD_UI" false)
    (lib.cmakeBool "LLAMA_OPENSSL" true)
    (lib.cmakeBool "BUILD_SHARED_LIBS" true)
  ];

  meta = {
    description = "llama.cpp fork: qwen4exp + MTP spec-decode + MoE expert residency, sm_75";
    homepage = "https://github.com/mjungnickel18/llama.cpp";
    license = lib.licenses.mit;
    mainProgram = "llama-server";
    platforms = [ "x86_64-linux" ];
  };
})
