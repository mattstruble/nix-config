# forecats-day-context

Given a date and a place, what was the day like — the sky, the schedule, and
whether the day has a name where the place is — as one immutable value with
the source and fetch time of every section.

It answers "what is today" and nothing else. No concept from whatever consumes
the answer belongs here, and `test_module_hygiene.py` fails the suite if one
appears.

## Running the suite

The suite needs `recurring-ical-events` and `google-api-python-client`. The
ambient interpreter on a build machine has pytest and neither, and a run that
skips the calendar files reports green over the two acceptance criteria that
matter most — so the environment is declared, in the flake, and the gate names
it.

```sh
# from the repository root
nix build .#day-context-env --print-out-paths
```

Check: a store path ending `python3-3.14.7-env`. Until `nix/forecats-day-context.nix`
is tracked, flakes cannot see it and the same environment builds from the
expression directly:

```sh
nix build --impure --no-link --print-out-paths --expr '
  let f = builtins.getFlake "/Users/mestruble/Software/nix-config";
      pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
      module = import ./nix/forecats-day-context.nix {};
  in (module.perSystem { inherit pkgs; }).packages.day-context-env'
```

Then run both gates with that interpreter, never with `python3` from `PATH`:

```sh
GATE=$(nix build .#day-context-env --print-out-paths --no-link)/bin/python

"$GATE" -m pytest src/forecats-day-context -q
```

Check: `100 passed`. Any `skipped` in that output is a failure of the
environment, not of the code — read which file skipped before moving on.

```sh
"$GATE" -c "import sys, socket
class Blocked(socket.socket):
    def __init__(self, *a, **k): raise AssertionError('network at import')
    def connect(self, *a, **k): raise AssertionError('network at import')
socket.socket = Blocked
sys.path.insert(0, 'src/forecats-day-context')
import day_context
print('import clean, exports:', len(day_context.__all__))"
```

Check: `import clean, exports: 25`.

No test reads a credential or opens a socket. Providers take an `HttpFetcher`
and every test hands them one that answers from `fixtures/`, so this holds by
construction rather than by the suite being careful.

## Secrets

Two providers take a secret as a constructor argument and never read it from
the environment: the Home Assistant token, and the ICS feed URL — which is a
secret because it carries a bearer token, whoever published it. Keeping them
out of module scope is what lets this package be imported, and its tests run,
on a machine that has neither.

## Layout

| file | holds |
|---|---|
| `day_context/contracts.py` | the vocabulary a provider implements against |
| `day_context/weather.py`, `schedule.py`, `observances.py` | the domain values |
| `day_context/day.py` | `DayContext`, and the one function that assembles it |
| `day_context/http_transport.py` | the only place a socket is opened |
| `day_context/weather_*.py`, `schedule_*.py`, `observances_*.py` | one provider per file |
| `A-B-PROVIDERS.md` | which provider won, what was measured, and why the loser is still here |
