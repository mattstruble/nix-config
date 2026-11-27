{
  lib,
  fetchFromGitHub,
  cmake,
  ninja,
  autoAddDriverRunpath,
  cudaPackages,
}:
# stable-diffusion.cpp at the commit the h3-image prototype validated: 532d2c1
# (2026-11-15). The nixpkgs build is master-874 and its MiniMax-H3 version
# detector demands an `audio_patch_proj` tensor that the image-pruned GGUF this
# pipeline renders with does not carry, so it refuses the weights with
# "get sd version from file failed" before drawing anything. 532d2c1 detects
# `Version: MiniMax-H3-Image` from the same file — verified on mjolnir against
# both binaries on 2026-11-27.
#
# Flags mirror /home/mestruble/h3image/stable-diffusion.cpp/build/CMakeCache.txt
# (the build the prototype rendered with): Release, SD_CUDA=ON, static libs,
# sm_75, flash-attention quants at the default set. CUTLASS is header-only and
# only exercised on Blackwell; libwebp/libwebm gate WebP/WebM output, which a
# nightly PNG never makes; the server example needs the webui submodule, so it
# is off — the only consumer is sd-cli.
let
  # The ggml submodule sd.cpp pins: leejet/ggml at the commit recorded in the
  # validated checkout. add_subdirectory(ggml) needs it as a plain source dir,
  # so the fetch is placed over the empty submodule directory in postUnpack.
  ggml = fetchFromGitHub {
    owner = "leejet";
    repo = "ggml";
    rev = "eeda9ec48fc84a3df0bb9dcc19ae9053075a2539"; # pragma: allowlist secret (git commit id, not a secret)
    hash = "sha256-AHhLPIidPDj+CThJ1AkOdrKTMySE+SBtFuTaXSq+woM="; # pragma: allowlist secret
  };
  # CUTLASS at the version the validated checkout pins (v3.9.2): the CUDA build
  # configures it unconditionally and refuses to configure without the headers
  # (cmake/cutlass.cmake:14), and the prototype carried it, so disabling it
  # would be building something the panel was not validated against.
  cutlass = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "cutlass";
    rev = "ad7b2f5e84fcfa124cb02b91d5bd26d238c0459e"; # pragma: allowlist secret (v3.9.2 git commit id)
    hash = "sha256-teziPNA9csYvhkG5t2ht8W8x5+1YGGbHm8VKx4JoxgI="; # pragma: allowlist secret
  };

in
cudaPackages.backendStdenv.mkDerivation (finalAttrs: {
  pname = "sd-cli";
  version = "532d2c1";

  src = fetchFromGitHub {
    owner = "leejet";
    repo = "stable-diffusion.cpp";
    rev = "532d2c15c430a785a712b2d94281f04e733008a4"; # pragma: allowlist secret (git commit id, not a secret)
    hash = "sha256-rNgLrALVsBVx8S1MX1GiWyfW446OpLYPUwVRbn7d6gY="; # pragma: allowlist secret
  };

  nativeBuildInputs = [
    cmake
    ninja
    # The toolkit's CMake package configs: ggml's CUDA path does its own
    # find_package(CUDAToolkit) and refuses to configure without it, which the
    # nvcc wrapper hook satisfies.
    cudaPackages.cuda_nvcc
    autoAddDriverRunpath
  ];

  buildInputs = [
    cudaPackages.cccl
    cudaPackages.cuda_cudart
    cudaPackages.libcublas
  ];

  postUnpack = ''
    rmdir $sourceRoot/ggml
    cp -r ${ggml} $sourceRoot/ggml
    chmod -R u+w $sourceRoot/ggml
    rmdir $sourceRoot/thirdparty/cutlass
    cp -r ${cutlass} $sourceRoot/thirdparty/cutlass
    chmod -R u+w $sourceRoot/thirdparty/cutlass
  '';

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=Release"
    "-DSD_CUDA=ON"
    "-DSD_BUILD_SHARED_LIBS=OFF"
    "-DSD_BUILD_SERVER=OFF"
    "-DCMAKE_CUDA_ARCHITECTURES=75"
    "-DGGML_CUDA_FA=ON"
    "-DGGML_CUDA_FA_ALL_QUANTS=OFF"
  ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m755 bin/sd-cli $out/bin/sd-cli
    runHook postInstall
  '';

  meta = {
    description = "stable-diffusion.cpp sd-cli pinned at the MiniMax-H3-Image-validating commit";
    mainProgram = "sd-cli";
    platforms = [ "x86_64-linux" ];
  };
})
