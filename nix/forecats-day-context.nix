{ ... }:
{
  # The suite runs against the calendar expander the chosen provider uses and
  # the client the fallback provider uses, because both are exercised; the
  # weather providers are standard library only and need nothing here.
  #
  # The nixpkgs attribute for a Python package is its PyPI distribution name,
  # hyphens and all — `recurring-ical-events`, not `recurring_ical_events`,
  # which is the import name and evaluates to nothing.
  perSystem =
    { pkgs, ... }:
    let
      # The ambient interpreter is not a substitute for this one: it has
      # pytest and nothing else, and a suite that skipped its calendar cases
      # would report green over the two criteria that matter most.
      testEnv = pkgs.python3.withPackages (
        ps: with ps; [
          recurring-ical-events
          google-api-python-client
          pytest
        ]
      );
    in
    {
      packages.day-context-env = testEnv;

      # nix develop .#day-context
      #   python3 -m pytest src/forecats-day-context -q
      devShells.day-context = pkgs.mkShell {
        packages = [ testEnv ];
      };
    };
}
