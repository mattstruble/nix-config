# Provider A/B: what was measured, and which way it fell

Two sources, two candidates each, run against each other rather than reasoned
about. Where a number below is a measurement it says how it was taken; where
a candidate could not be exercised for real, that is stated as the limitation
it is.

## The metric that matters here, and the one that does not

This deploys through nix, so the cost of a dependency is "is it in nixpkgs,
and what does it add to the store closure" — not "how many distributions does
pip install". The pip count was measured first and it ranked the calendar
candidates 7 against 22. That ranking is wrong and is recorded here only so
nobody re-derives it.

Measured against the nixpkgs pinned by `flake.lock` (rev `4975466d3247`,
python 3.14.7), as the set of python packages in the runtime closure of
`python3.withPackages [ <candidate> ]`:

| candidate | nix python-package closure | all present in the pinned nixpkgs |
|---|---|---|
| standard library only | 0 | — |
| `recurring-ical-events` 3.9.0 | 7 | yes |
| `google-api-python-client` 2.192.0 | 20 | yes |
| `requests` | 5 | yes |

Both calendar candidates are fully packaged, including the parts with native
builds (`cryptography`, `protobuf`). **Closure size does not separate the two
calendar candidates.** It does decide the weather question, where the standard
library route costs nothing at all.

## Weather: Open-Meteo over Home Assistant REST

**Open-Meteo wins. Home Assistant REST is kept as the named fallback.**

Probed live against `api.open-meteo.com` on 2026-11-16.

| axis | Open-Meteo | Home Assistant REST |
|---|---|---|
| credential surface | none | a long-lived token, and the URL of the instance |
| nix closure | 0 | 0 (standard library `urllib`) |
| forecast horizon | 16 days, hard ceiling; `forecast_days=17` is HTTP 400 | whatever the configured integration emits — not a property of this code |
| granularity | requested per variable, daily or hourly | whatever the configured integration emits |
| "no data" vs "no precipitation" | **not carried by value**; carried by HTTP status and by whether the requested date appears as a row | carried by key presence in the forecast entry |

The horizon row is the one that decides it. A Home Assistant `weather.*`
entity is a proxy for an integration, so the number of days and the step size
this module could rely on is a fact about whichever integration the host
happens to have configured. Open-Meteo's ceiling is a published number that
can be written down.

The no-data row is the axis Home Assistant wins, and it is worth being exact
about why it did not decide the contest. Open-Meteo answers a dry day with
`0.0` and, in every response captured for this work, has never answered with
`null` — including locations and model overrides chosen to try to provoke one.
So within a response the two states are indistinguishable, and the only
honest signal is row presence. That is a constraint the provider encodes
(`weather_open_meteo.py` refuses a response that does not contain the
requested date) rather than a reason to prefer the other candidate: Home
Assistant wins the axis by having a shape that makes the distinction, and
loses the axes above it.

The decisive reason is the epic this ticket sits under: the point is to run
without Home Assistant. A weather provider that needs a Home Assistant token
has not moved anything off the host.

**Why Home Assistant is kept rather than deleted:** a host that already runs
it already has the data, needs no new egress, and pays nothing in nix. It
loses on credential surface and on having no contract about horizon, not on
being unable to answer.

**Limitation, stated plainly:** the Home Assistant provider is tested against
fixtures written from Home Assistant's documented `weather` entity shape. No
token was used and no live instance was contacted. That proves the provider
reads the documented contract and refuses where the contract is silent. It
does not prove any running instance serves that shape.

## Calendar: ICS feed over the Google Events API

**ICS + `recurring-ical-events` wins. `GoogleEventsCalendarProvider` is kept
as the named fallback.**

Neither candidate was rejected on dependencies; both are packaged. They were
separated on credential surface and on where recurrence expansion happens.

| axis | ICS feed + `recurring-ical-events` | Events API, `singleEvents=true` |
|---|---|---|
| secret stored | one URL. It is a bearer secret: whoever holds it can read the calendar. It does not expire and has no scope | an OAuth client plus a refresh token, with a consent screen behind it |
| revocation | delete the URL, or unpublish the calendar | revoke the grant, and survive the window until it takes effect |
| lifetime | indefinite | a refresh token that Google may retire; nightly job, so this is a nightly failure mode |
| where recurrence is expanded | here | on a Google server |
| nix closure | 7 | 20 |

The `singleEvents=true` axis cuts both ways and the trade is worth stating
without a favourite side. Expanding server-side deletes the code that could
be wrong about daylight saving and about the 31st — and with it the test that
could have caught the error. The acceptance criteria for this ticket are
behavioural: a DST case, a month-end case, an all-day case. Under the API
route those cases are Google's behaviour, not this module's, and there is no
fixture that can assert them. Under the ICS route they are this module's, and
`test_schedule_ics.py` is what they look like when they break.

**Why the API route is kept rather than deleted:** it is the only candidate
that works for a calendar whose owner will not publish a feed, and it removes
the recurrence engine from the trusted computing base. If the recurrence
fixtures ever disagree with a real calendar more than once, that is the
argument that flips, and the code to flip back is here.

## What the fixture taught, in the order it was found

These are constraints from outside this repository. Each is the reason a line
of this module exists.

1. **Subtracting two aware datetimes that share a `tzinfo` object answers in
   wall clock.** On 2026-03-08 in America/New_York, `03:30 - 01:30` answers
   2h30m; 90 minutes of that day happened. Comparison uses instants and is
   fine; only subtraction short-circuits. Every duration and overlap in this
   module routes through UTC.
2. **`astimezone(zone)` is a no-op when the zone is already attached.** A
   recurring 02:30 occurrence on a spring-forward day arrives from the library
   stamped 02:30, which is not a time anyone can look at. Normalising it means
   leaving the zone and coming back.
3. **A DST gap can invert an event.** A weekly 02:30–03:00 occurrence on the
   day 02:30 does not exist expands to a start after its end. The start is the
   event's identity, so it wins and the end takes the stated length rather
   than the stated wall clock time.
4. **`UNTIL` is compared in UTC.** A monthly-on-the-31st rule written
   `UNTIL=20261231T235959Z` silently drops the 31 December occurrence, because
   31 December 20::00 New York is 1 January 01:00 UTC. The fixture's first
   version had this bug and the month-end test caught it.
5. **`DTEND` on an all-day event is exclusive.** A trip dated 07 to 09 is on
   the calendar for the 7th and the 8th and not for the 9th.
6. **Open-Meteo answers an out-of-range window with HTTP 400 and a `reason`.**
   An early reading of this as a silent empty response was wrong, and was
   wrong because the HTTP status was not checked before parsing the body. The
   lesson is the provider's rule: a status that is not 2xx is a failure with
   the server's reason, and a response with no row for the requested day is a
   failure too.
