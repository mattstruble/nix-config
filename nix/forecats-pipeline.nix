{ inputs, ... }:
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
      storage = inputs.self.forecatsStorage;
      runtimeDeps =
        ps: with ps; [
          pillow
          pyyaml
          recurring-ical-events
        ];
      runtimePython = pkgs.python3.withPackages runtimeDeps;
      testPython = pkgs.python3.withPackages (ps: runtimeDeps ps ++ [ ps.pytest ]);
      panelFont = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf";

      # The two directories a render reads, taken from the declaration that creates
      # them: `forecatsStorage` in nix/services/k3s.nix makes the host directories and
      # the local volumes over them. Written once for both wrappers so the nightly and
      # the placement step cannot disagree, and as `${VAR:-default}` because a pod that
      # mounts a volume at another mount point names its own.
      volumeExports = ''
        export FORECATS_MODEL_DIRECTORY="''${FORECATS_MODEL_DIRECTORY:-${storage.volumes.weights.hostPath}}"
        export FORECATS_PHOTO_DIRECTORY="''${FORECATS_PHOTO_DIRECTORY:-${storage.volumes.photos.hostPath}}"
      '';

      # The two trees, as the installed layout names them. Both entry points run
      # one interpreter over both, and the path is written once so the wrappers
      # cannot disagree about it.
      pythonPath = "${placeholder "out"}/src/forecats-day-context:${placeholder "out"}/src/forecats-pipeline";
    in
    {
      packages.pipeline-env = testPython;

      # nix run .#forecats-pipeline -- --timezone America/New_York \
      #   --latitude 40.7128 --longitude -74.006 --output-dir ~/panels
      #
      # One nightly render, on a host with no checkout: every path the run needs
      # — the two source trees, the panel font, the household file — is a store
      # path fixed in at build time, and the two volume directories the render reads
      # are exported above from the declaration that creates them. The diffusion CLI
      # is the one input that is not: the only nixpkgs build of it that renders on a
      # card does not evaluate on every host this package is built for, so the render
      # host supplies it and names it. The devShell below cannot say any of that; its
      # PYTHONPATH is relative to a repository root, which is the thing that tied the
      # pipeline to the laptop it was developed on.
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

          # No diffusion CLI in this closure, and the install check below is what
          # keeps that a decision rather than an oversight. The render host
          # supplies the CLI and names it with `--sd-cli-binary`, or puts it first
          # on PATH.

          cat > "$out/bin/forecats-pipeline" <<'WRAPPER'
          #!/bin/sh
          set -eu

          export FORECATS_PANEL_FONT='${panelFont}'
          export PYTHONPATH='${pythonPath}'
          ${volumeExports}

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

          # The placement step of RUNBOOK.md, as a command rather than a
          # `python3 -m` line a person has to assemble: the weights and the
          # reference photos are host data, and this is what puts them where a
          # render looks. Same interpreter and same two trees as the nightly.
          cat > "$out/bin/forecats-stage-inputs" <<'WRAPPER'
          #!/bin/sh
          set -eu

          export PYTHONPATH='${pythonPath}'
          ${volumeExports}

          exec '${runtimePython}/bin/python3' -m forecats_pipeline.stage_inputs "$@"
          WRAPPER
          chmod +x "$out/bin/forecats-stage-inputs"

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
          # The suite reads the two volume directories out of the environment, the
          # way the nightly does: the household file names its photos by absolute
          # path, and what it has to agree with is the declaration, not a copy of the
          # path written into a test.
          ${volumeExports}
          PYTHONPATH="$installed/forecats-day-context:$installed/forecats-pipeline" python3 -m pytest -q .

          # The suite above imports the package; it never runs a wrapper, and the
          # wrappers are where the packaging is: the two PYTHONPATH entries, the
          # font export, the household default, the module name, the quoting of
          # every one of them. Each is a store path or an escape that builds green
          # when it is wrong and fails on the nightly, so one nightly runs here,
          # through the installed entry point.
          #
          # The calendar is the day-context fixture over `file:` because a build
          # has no network and a feed address is a credential; the sky is
          # --weather because Open-Meteo is a socket; the renderer is the fake one
          # because a real render wants a card and 18 GB of weights. What is left
          # under test is the packaging — the interpreter, both trees, the
          # household file the wrapper defaults to, and the font, which only
          # --draw-forecast-plate reads and which a mangled export turns into a
          # refusal rather than a panel. The day is one the fixture calendar has
          # events on, so the run gathers a day rather than an empty one.
          day=2026-03-08
          panels="$PWD/panels"
          # The report address arrives the way the render pod will hand it over:
          # named outside the package and read from the environment. The closure
          # holds no address of its own — the real one is personal data, and a
          # wrapper that defaulted it would publish a mailbox nobody reads beside
          # every panel.
          PYTHONDONTWRITEBYTECODE=1 \
          FORECATS_CALENDAR_FEEDS="check=file://${placeholder "out"}/src/forecats-day-context/fixtures/day.ics" \
          FORECATS_REPORT_ADDRESS="check@forecats.invalid" \
            "${placeholder "out"}/bin/forecats-pipeline" \
            --day "$day" \
            --timezone America/New_York \
            --latitude 40.7128 \
            --longitude -74.006 \
            --output-dir "$panels" \
            --renderer fake \
            --weather snow --high 1 --low -3 \
            --draw-forecast-plate
          test -s "$panels/panel-$day.png"
          test -s "$panels/panel-$day.provenance.json"

          # The other names a page fetches. They are checked here and not only in
          # the suite because the installed wrapper's own run writes them: a build
          # whose interpreter had no Pillow, or whose wrapper pointed at another
          # output directory, publishes a panel with no banner beside it, and the
          # wall is where that would surface.
          test -s "$panels/panel-$day-banner.png"
          test -s "$panels/panel-$day-thumb.png"
          test -s "$panels/panel-$day.prompt.json"
          test -s "$panels/gallery.json"

          # The index names the day and every rendition the volume holds, and the
          # public artefact beside the panel carries neither an address nor a path
          # into the photo volume. A viewer may serve the index and the prompt
          # artefact and refuses the sidecar, so this is where the line between the
          # two is drawn before a wall reads either.
          PANELS="$panels" PANEL_DAY="$day" python3 <<'PY'
          import json
          import os
          from pathlib import Path

          panels = Path(os.environ["PANELS"])
          gallery = json.loads((panels / "gallery.json").read_text(encoding="utf-8"))
          (entry,) = gallery["days"]
          assert entry["day"] == os.environ["PANEL_DAY"], entry
          assert sorted(entry["variants"]) == ["banner", "full", "thumb"], entry
          for name in entry["variants"].values():
              assert (panels / name).is_file(), name

          published = (panels / entry["prompt"]).read_text(encoding="utf-8")
          assert "@" not in published, "the published prompt artefact carries an address"
          assert "/var/lib/" not in published, "the published prompt artefact carries a path"
          PY

          # Existence is not the plate. The fake renderer's placeholder is one flat
          # colour, so a published file carrying more than one is what says the
          # overlay ran and opened the font it was handed: a panel published with
          # its plate missing is otherwise a panel that looks published.
          PANEL="$panels/panel-$day.png" python3 <<'PY'
          import os

          from PIL import Image

          panel = Image.open(os.environ["PANEL"]).convert("RGB")
          # A w×h image holds at most w×h colours, so this is the one bound
          # `getcolors` cannot answer with None.
          plate = panel.getcolors(maxcolors=panel.width * panel.height)
          assert len(plate) > 1, f"{os.environ['PANEL']} is a flat field: no forecast plate"
          PY

          # Existence is not the report address. The grant obliges the owner to keep a
          # way to report a violation reachable from the panel, and the sidecar beside
          # the picture is what a viewer has — so this is where the build checks that
          # the value named above arrived there rather than being read and dropped.
          PROVENANCE="$panels/panel-$day.provenance.json" python3 <<'PY'
          import json
          import os

          with open(os.environ["PROVENANCE"], encoding="utf-8") as sidecar:
              record = json.load(sidecar)
          assert record["report_address"] == "check@forecats.invalid", record.get("report_address")
          PY

          # A build has no weights, so the real renderer has nowhere to read from —
          # which is the state a volume that mounted empty leaves, and the one case
          # that must refuse before the CLI is spawned. What this checks is the
          # export, so the two variables are taken away from this run: the directory
          # named on the refusal line has to have come from the wrapper, and a
          # pipeline that fell back to a default of its own fails the build here.
          refused="$PWD/sd-cli-refusal.txt"
          if env -u FORECATS_MODEL_DIRECTORY -u FORECATS_PHOTO_DIRECTORY \
            PYTHONDONTWRITEBYTECODE=1 \
            FORECATS_CALENDAR_FEEDS="check=file://${placeholder "out"}/src/forecats-day-context/fixtures/day.ics" \
            FORECATS_REPORT_ADDRESS="check@forecats.invalid" \
            NVIDIA_VISIBLE_DEVICES=1 \
            "${placeholder "out"}/bin/forecats-pipeline" \
            --day "$day" \
            --timezone America/New_York \
            --latitude 40.7128 \
            --longitude -74.006 \
            --output-dir "$PWD/panels-refused" \
            --renderer sd-cli \
            --weather snow --high 1 --low -3 \
            >"$refused" 2>&1; then
            echo "error: a render with no weights anywhere on this host exited 0" >&2
            exit 1
          fi
          grep -q "${storage.volumes.weights.hostPath}" "$refused" || {
            echo "error: the render refused without naming ${storage.volumes.weights.hostPath}, so the directory it read did not come from the storage declaration" >&2
            cat "$refused" >&2
            exit 1
          }

          # The other wrapper: same interpreter, same two trees, its own module
          # name to get wrong.
          PYTHONDONTWRITEBYTECODE=1 "${placeholder "out"}/bin/forecats-stage-inputs" --help >/dev/null

          # The closure carries no diffusion CLI, and this is the line that keeps
          # that a decision. `stable-diffusion-cpp-cuda`, the build that renders on
          # a card, does not evaluate on aarch64-darwin and pulls the unfree CUDA
          # toolkit into a package installed on hosts that never render; the build
          # that does evaluate everywhere is the portable one, and a render that
          # fell back to the driver stub exits 0 — measured on the render host at
          # 1627 s against 14.86 s on the card. Any store-built CLI named here
          # would make a silently-CPU nightly green.
          test ! -e "${placeholder "out"}/bin/sd-cli"

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
        # The same two directories the installed wrappers export, so the suite
        # checks the household file and the staging defaults against the storage
        # declaration rather than against a path written down in a test.
        env.FORECATS_MODEL_DIRECTORY = storage.volumes.weights.hostPath;
        env.FORECATS_PHOTO_DIRECTORY = storage.volumes.photos.hostPath;
      };
    };
}
