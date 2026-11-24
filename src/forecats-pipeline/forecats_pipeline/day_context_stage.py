"""Stage 1: ask the day-context layer what today was, and keep what it said.

The providers are already honest — each answers with a `Fetched` value or a
`ProviderFailure`, and never raises for an outage it cannot control. This
stage's whole job is to not launder that honesty away: a failure becomes a
recorded refusal naming its cause, never an empty field, and a day whose sky
could not be read produces no `DayContext` at all.

Providers are injected rather than constructed here so that the nightly wiring
(`pipeline.py`) decides which weather source is primary and where the calendar
feed lives, and so no module in this package reads the environment or opens a
socket at import time.
"""

from collections.abc import Mapping, Sequence
from datetime import date, datetime, timezone
from urllib.parse import urlsplit

from day_context import (
    CalendarProvider,
    Location,
    ProviderFailure,
    WeatherDay,
    WeatherProvider,
)
from day_context.http_transport import HttpFetcher
from day_context.schedule import CalendarDay

from forecats_pipeline.contracts import (
    DayContext,
    Occasion,
    PipelineRefusal,
    WeatherToday,
)

__all__ = ["PayloadLog", "RecordingFetcher", "build_day_context"]


class PayloadLog:
    """The body each source answered with, kept for the provenance sidecar.

    Filed under the label the source is configured under, never under the URL it
    was fetched from: the sidecar is written to the volume the panel server
    publishes, and a private feed address carries the read token of the calendar
    in its path or query, so a body logged under its address publishes the
    calendar beside the picture of a cat.

    Two feeds sharing one label keep two entries, because one body filed under
    another's name is a record that lies about which feed it came from. The log
    is held by the caller, not by the `DayContext`: provenance is a publishing
    concern and a day is not obliged to be published.
    """

    def __init__(self, names: Mapping[str, str] | None = None) -> None:
        """`names` maps each source's URL to the label it is configured under."""
        self._names = {url: label.strip() for url, label in (names or {}).items()}
        self._bodies: dict[str, object] = {}
        self._owners: dict[str, str] = {}

    def record(self, url: str, body: object) -> None:
        self._bodies[self._entry_for(url)] = body

    def bodies(self) -> dict[str, object]:
        return dict(self._bodies)

    def _entry_for(self, url: str) -> str:
        """The entry this URL writes: its name, or the next free slot under it."""
        name = self._names.get(url) or _host_of(url)
        entry = name
        slot = 1
        holder = self._owners.get(entry)
        while holder is not None and holder != url:
            slot += 1
            entry = f"{name}#{slot}"
            holder = self._owners.get(entry)
        self._owners[entry] = url
        return entry


def _host_of(url: str) -> str:
    """The one part of an address that names a source without being one.

    Only a source configured with no label needs this. A feed's token rides in
    the path or the query (`/public-calendars/<token>`, `?key=<token>`), so a
    name taken from either would be the credential itself.
    """
    return urlsplit(url).hostname or "unlabelled source"


class RecordingFetcher:
    """An `HttpFetcher` that keeps what it was given, beside passing it on."""

    def __init__(self, inner: HttpFetcher, log: PayloadLog) -> None:
        self._inner = inner
        self._log = log

    def get_json(self, url: str, headers: Mapping[str, str] | None = None) -> dict[str, object]:
        payload = self._inner.get_json(url, headers)
        self._log.record(url, payload)
        return payload

    def get_text(self, url: str, headers: Mapping[str, str] | None = None) -> str:
        text = self._inner.get_text(url, headers)
        self._log.record(url, text)
        return text


class CachingFetcher:
    """An `HttpFetcher` that asks for a URL once per run.

    A lookahead over five days asks the calendar the same question five times, and
    every one of those questions downloads the whole ICS feed. The feeds do not
    change during a run, and re-reading one five times is five chances for the
    answer to disagree with itself.
    """

    def __init__(self, inner: HttpFetcher) -> None:
        self._inner = inner
        self._json: dict[str, dict[str, object]] = {}
        self._text: dict[str, str] = {}

    def get_json(self, url: str, headers: Mapping[str, str] | None = None) -> dict[str, object]:
        if url not in self._json:
            self._json[url] = self._inner.get_json(url, headers)
        return self._json[url]

    def get_text(self, url: str, headers: Mapping[str, str] | None = None) -> str:
        if url not in self._text:
            self._text[url] = self._inner.get_text(url, headers)
        return self._text[url]


def build_day_context(
    day: date,
    location: Location,
    *,
    weather_providers: Sequence[WeatherProvider],
    calendar_provider: CalendarProvider,
    assembled_at: datetime | None = None,
) -> DayContext | PipelineRefusal:
    """Gather one day, or refuse and name every source that could not answer.

    Weather is asked of each provider in preference order; the first that
    answers wins and the ones before it are still recorded. A calendar that
    did not answer is not a reason to skip the day — an empty schedule is a
    claim the panel can make — but it is recorded beside whatever it says.
    """
    if not weather_providers:
        raise ValueError("at least one weather provider is required; a sky was not fetched")

    panel_time = assembled_at or datetime.now(timezone.utc)
    weather, weather_refusals = _ask_weather(day, location, weather_providers, panel_time)
    if weather is None:
        return PipelineRefusal(
            stage="weather",
            reason="; ".join(weather_refusals) or "no weather provider was consulted",
        )

    occasions, calendar_refusals = _ask_calendar(day, location, calendar_provider)
    return DayContext(
        for_day=day,
        timezone=location.timezone,
        weather=weather,
        occasions=occasions,
        weather_refusals=weather_refusals,
        calendar_refusals=calendar_refusals,
    )


def _ask_weather(
    day: date,
    location: Location,
    providers: Sequence[WeatherProvider],
    panel_time: datetime,
) -> tuple[WeatherToday | None, tuple[str, ...]]:
    refusals: list[str] = []
    for provider in providers:
        answer = provider.fetch_weather(location, day)
        if isinstance(answer, ProviderFailure):
            refusals.append(f"{answer.source}: {answer.kind.value}: {answer.reason}")
            continue

        unusable = _unusable_weather(answer.value)
        if unusable is not None:
            refusals.append(f"{answer.source}: no_data: {unusable}")
            continue

        return (
            _weather_today(answer.value, answer.source, answer.fetched_at, panel_time),
            tuple(refusals),
        )
    return None, tuple(refusals)


def _unusable_weather(source_day: WeatherDay) -> str | None:
    """Why this answer cannot become a `WeatherToday`, or None if it can.

    A quantity the source did not report is not zero. `WeatherToday` has no
    way to say "unknown", so an answer missing precipitation is refused here
    and the next provider gets its turn, rather than arriving at the renderer
    as a dry day.
    """
    if source_day.precipitation_mm is None:
        return "the source reported no precipitation amount for this day"
    if source_day.precipitation_probability_pct is None:
        return "the source reported no precipitation probability for this day"
    return None


def _weather_today(
    source_day: WeatherDay,
    source: str,
    fetched_at: datetime,
    panel_time: datetime,
) -> WeatherToday:
    return WeatherToday(
        summary=source_day.condition.value,
        # Both bounds, not the high alone: the panel's corner box shows a range,
        # and a viewer checks it against the same source the way forecats' does.
        temperature_high_c=source_day.temperature_max_c,
        temperature_low_c=source_day.temperature_min_c,
        precipitation_mm=source_day.precipitation_mm,
        precipitation_probability_pct=source_day.precipitation_probability_pct,
        is_daylight_at_panel_time=_is_daylight(source_day, panel_time),
        source=source,
        fetched_at=fetched_at,
    )


def _is_daylight(source_day: WeatherDay, panel_time: datetime) -> bool:
    """Whether the panel's moment falls between the day's sun times.

    A source that reported no sun times yields day, not night: the panel never
    claims a darkness it did not measure, and a day scene drawn at midnight is
    a cosmetic error in a way that a black panel is not.
    """
    if source_day.sunrise is None or source_day.sunset is None:
        return True
    return source_day.sunrise <= panel_time <= source_day.sunset


def _ask_calendar(
    day: date,
    location: Location,
    provider: CalendarProvider,
) -> tuple[tuple[Occasion, ...], tuple[str, ...]]:
    answer = provider.fetch_schedule(location, day)
    if isinstance(answer, ProviderFailure):
        return (), (f"{answer.source}: {answer.kind.value}: {answer.reason}",)
    return _occasions(answer.value), ()


def _occasions(calendar_day: CalendarDay) -> tuple[Occasion, ...]:
    # described_as stays None: the research stage has not run, and None is the
    # only honest record of "nobody asked" — False would read as "asked, means
    # nothing".
    return tuple(
        Occasion(title=event.summary, all_day=event.all_day) for event in calendar_day.events
    )
