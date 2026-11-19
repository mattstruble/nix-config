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
    { pkgs, ... }:
    let
      testEnv = pkgs.python3.withPackages (
        ps: with ps; [
          pillow
          pyyaml
          recurring-ical-events
          pytest
        ]
      );
      panelFont = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf";
    in
    {
      packages.pipeline-env = testEnv;

      # nix develop .#forecats-pipeline
      #   python3 -m pytest src/forecats-pipeline -q
      #
      # PYTHONPATH is relative to the repository root, which is where both
      # documented commands are run from. The pipeline imports the day-context
      # layer by package name, so a shell that only had one of the two source
      # directories on the path could not import the pipeline at all.
      devShells.forecats-pipeline = pkgs.mkShell {
        packages = [ testEnv ];

        env.PYTHONPATH = "src/forecats-day-context:src/forecats-pipeline";
        env.FORECATS_PANEL_FONT = panelFont;
      };
    };
}
