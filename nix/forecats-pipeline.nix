{ ... }:
{
  # The pipeline is standard library only: the weather and calendar providers
  # it composes are themselves stdlib plus the ICS expander, and adding a
  # framework here would be a second way to make an HTTP request.
  #
  # recurring-ical-events is present because the day-context layer imports it
  # at module scope, so a suite that exercises the calendar stage cannot load
  # without it.
  #
  # Pillow is the overlay stage: the forecast box is drawn from the forecast
  # rather than generated, so that the temperature on the wall is the one the
  # source reported. The font is a store path for the same reason — a font
  # resolved out of /usr/share is a pipeline that works until the host changes.
  #
  # The nixpkgs attribute for a Python package is its PyPI distribution name,
  # hyphens and all.
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      runtimeDeps =
        ps: with ps; [
          pillow
          pyyaml
          recurring-ical-events
        ];
      runtimePython = pkgs.python3.withPackages runtimeDeps;
      testPython = pkgs.python3.withPackages (ps: runtimeDeps ps ++ [ ps.pytest ]);
      panelFont = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf";

      # The diffusion CLI the render stage SSHes out and runs. It is part of this
      # package so that its runtime is rooted by a store path a host holds: a
      # hand-built binary on the render host died when nix collected the glibc
      # its interpreter came from.
      #
      # nixpkgs' portable build, not `stable-diffusion-cpp-cuda`: that one has no
      # substitute and pulls the unfree CUDA toolkit into a package whose own
      # code never runs the binary, it SSHes. The render host renders with its
      # own CUDA build named by `--sd-cli-binary`, which now has a store path to
      # point at instead of a name on a login PATH; the flag keeps its bare-name
      # default, so a host that already has its own binary on PATH is unaffected.
      sdCli = pkgs.stable-diffusion-cpp;
    in
    {
      packages.pipeline-env = testPython;

      # nix run .#forecats-pipeline -- --timezone America/New_York \
      #   --latitude 40.7128 --longitude -74.006 --output-dir ~/panels
      #
      # One nightly render, on a host with no checkout: every path the run needs
      # — the two source trees, the panel font, the household file, the diffusion
      # CLI — is a store path fixed in at build time. The devShell below cannot
      # say that; its PYTHONPATH is relative to a repository root, which is the
      # thing that tied the pipeline to the laptop it was developed on.
      packages.forecats-pipeline = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
        pname = "forecats-pipeline";
        version = "0";

        srcs = [
          ../src/forecats-pipeline
          ../src/forecats-day-context
        ];
        # Two trees and no common root, so unpack leaves both in the build
        # directory rather than under a directory neither of them is named.
        sourceRoot = ".";
        dontBuild = true;

        installPhase = ''
          runHook preInstall

          mkdir -p "$out/src" "$out/bin"

          # The trees stay siblings under the names they have in the repo: the
          # suite reaches the calendar fixture and the household file by paths
          # relative to its own files, so a flattened install fails tests for
          # reasons of packaging rather than of code.
          cp -r forecats-pipeline forecats-day-context "$out/src/"

          # Named for the binary the render stage runs, so that the copy this
          # closure carries is the copy `--sd-cli-binary` can name.
          ln -s ${sdCli}/bin/sd-cli "$out/bin/sd-cli"

          cat > "$out/bin/forecats-pipeline" <<'WRAPPER'
          #!/bin/sh
          set -eu

          export FORECATS_PANEL_FONT='${panelFont}'
          export PATH="${placeholder "out"}/bin''${PATH:+:$PATH}"
          export PYTHONPATH='${placeholder "out"}/src/forecats-day-context:${placeholder "out"}/src/forecats-pipeline'

          # The pipeline's own default for the household file is a path under a
          # repository root; the file that ships in this closure is the default
          # here, until a caller names another one.
          household_named=no
          for given in "$@"; do
            case $given in
              --household-file*) household_named=yes ;;
            esac
          done
          if [ "$household_named" = no ]; then
            set -- --household-file '${placeholder "out"}/src/forecats-pipeline/household.yaml' "$@"
          fi

          exec '${runtimePython}/bin/python3' -m forecats_pipeline "$@"
          WRAPPER
          chmod +x "$out/bin/forecats-pipeline"

          runHook postInstall
        '';

        # The suite runs against the installed tree, not the checkout, so the
        # artifact a host installs is the artifact that passed. `passthru.tests`
        # is the name to ask for it by.
        doInstallCheck = true;
        nativeInstallCheckInputs = [ testPython ];
        installCheckPhase = ''
          runHook preInstallCheck

          # $out is read-only and pytest writes its cache beside the files it
          # collects, so the suite runs against a copy. The copy keeps the `src/`
          # layout, because that is what the fixtures are resolved against.
          installed="$PWD/src"
          cp -r "${placeholder "out"}/src" "$installed"
          chmod -R u+w "$installed"
          cd "$installed/forecats-pipeline"
          PYTHONPATH="$installed/forecats-day-context:$installed/forecats-pipeline" python3 -m pytest -q .

          runHook postInstallCheck
        '';

        passthru.tests = finalAttrs.finalPackage;

        meta = {
          description = "Nightly weather-and-occasion panel of the household cats";
          license = lib.licenses.mit;
          mainProgram = "forecats-pipeline";
          platforms = lib.platforms.unix;
        };
      });

      # nix develop .#forecats-pipeline
      #   python3 -m pytest src/forecats-pipeline -q
      #
      # PYTHONPATH is relative to the repository root, which is where both
      # documented commands are run from. The pipeline imports the day-context
      # layer by package name, so a shell that only had one of the two source
      # directories on the path could not import the pipeline at all.
      devShells.forecats-pipeline = pkgs.mkShell {
        packages = [ testPython ];

        env.PYTHONPATH = "src/forecats-day-context:src/forecats-pipeline";
        env.FORECATS_PANEL_FONT = panelFont;
      };
    };
}
