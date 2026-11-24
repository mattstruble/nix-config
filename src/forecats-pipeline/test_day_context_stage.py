"""Stage 1 must not be able to hand the renderer a silently empty day.

The weather providers and the ICS expander have their own suites; what is
tested here is the translation between them and `DayContext`, which is where a
provider failure could turn into an empty field.
"""

from datetime import date

from conftest import DAY, DAY_ICS, FEED_URL, MORNING, StubFeed, StubWeatherProvider
from day_context import (
    Fetched,
    FailureKind,
    Location,
    ProviderFailure,
    WeatherCondition,
    WeatherDay,
)
from day_context.http_transport import TransportError
from day_context.schedule_ics import IcsCalendarProvider
from forecats_pipeline.contracts import PipelineRefusal
from forecats_pipeline.day_context_stage import PayloadLog, RecordingFetcher, build_day_context


def ics_provider() -> IcsCalendarProvider:
    return IcsCalendarProvider(StubFeed(text=DAY_ICS.read_text(encoding="utf-8")), FEED_URL)


def failing_ics_provider() -> IcsCalendarProvider:
    return IcsCalendarProvider(
        StubFeed(error=TransportError(FEED_URL, "no usable response: [Errno 61] Connection refused")),
        FEED_URL,
    )


def fetched_weather(
    source: str = "open-meteo",
    *,
    condition: WeatherCondition = WeatherCondition.RAIN,
    precipitation_mm: float | None = 12.0,
    precipitation_probability_pct: int | None = 90,
) -> Fetched[WeatherDay]:
    return Fetched(
        value=WeatherDay(
            day=DAY,
            condition=condition,
            temperature_min_c=1.0,
            temperature_max_c=7.5,
            precipitation_mm=precipitation_mm,
            precipitation_probability_pct=precipitation_probability_pct,
        ),
        source=source,
        fetched_at=MORNING,
    )


def sky(source: str = "open-meteo", **over) -> StubWeatherProvider:
    return StubWeatherProvider(source, fetched_weather(source, **over))


def down(source: str, kind: FailureKind, reason: str) -> StubWeatherProvider:
    return StubWeatherProvider(source, ProviderFailure(source, kind, reason))


def test_a_day_is_the_sky_plus_whatever_the_feed_shows(new_york: Location):
    context = build_day_context(
        DAY,
        new_york,
        weather_providers=[sky()],
        calendar_provider=ics_provider(),
        assembled_at=MORNING,
    )

    assert context.weather is not None
    assert context.weather.summary == "rain"
    assert context.weather.temperature_high_c == 7.5
    marked = {occasion.title: occasion.all_day for occasion in context.occasions}
    assert marked["Overlap A"] is False
    assert marked["Weekly Sunday call"] is False
    assert marked["Two day all day trip"] is True


def test_the_fallback_sky_answers_and_the_primary_failure_stays_recorded(new_york: Location):
    context = build_day_context(
        DAY,
        new_york,
        weather_providers=[down("open-meteo", FailureKind.UNREACHABLE, "no route to host"), sky("home-assistant")],
        calendar_provider=ics_provider(),
        assembled_at=MORNING,
    )

    assert context.weather is not None
    assert context.weather.source == "home-assistant"
    assert context.weather_refusals == ("open-meteo: unreachable: no route to host",)


def test_both_skies_down_refuses_and_names_every_cause(new_york: Location):
    refusal = build_day_context(
        DAY,
        new_york,
        weather_providers=[
            down("open-meteo", FailureKind.UNREACHABLE, "no route to host"),
            down("home-assistant", FailureKind.UNAUTHORIZED, "token expired"),
        ],
        calendar_provider=ics_provider(),
        assembled_at=MORNING,
    )

    assert isinstance(refusal, PipelineRefusal)
    assert refusal.stage == "weather"
    assert "open-meteo: unreachable: no route to host" in refusal.reason
    assert "home-assistant: unauthorized: token expired" in refusal.reason


def test_a_sky_that_did_not_report_precipitation_is_refused_not_dried_out(new_york: Location):
    """A quantity the source left blank must not reach the renderer as zero."""
    refusal = build_day_context(
        DAY,
        new_york,
        weather_providers=[sky(precipitation_mm=None, precipitation_probability_pct=None)],
        calendar_provider=ics_provider(),
        assembled_at=MORNING,
    )

    assert isinstance(refusal, PipelineRefusal)
    assert "open-meteo: no_data:" in refusal.reason
    assert "precipitation amount" in refusal.reason


def test_a_dead_feed_leaves_the_day_renderable_and_names_the_feed_that_died(new_york: Location):
    context = build_day_context(
        DAY,
        new_york,
        weather_providers=[sky()],
        calendar_provider=failing_ics_provider(),
        assembled_at=MORNING,
    )

    assert context.occasions == ()
    assert context.calendar_refusals == (
        "ics-feed: unreachable: no usable response: [Errno 61] Connection refused",
    )


def test_the_payload_log_holds_the_body_each_source_answered(new_york: Location):
    """Provenance records what was said, not what was understood from it."""
    log = PayloadLog({FEED_URL: "day feed"})
    feed = RecordingFetcher(StubFeed(text=DAY_ICS.read_text(encoding="utf-8")), log)

    IcsCalendarProvider(feed, FEED_URL).fetch_schedule(new_york, date(2026, 3, 8))

    assert log.bodies()["day feed"].startswith("BEGIN:VCALENDAR")


def test_no_payload_is_filed_under_the_address_it_was_fetched_from():
    """The log is published beside the panel; the address is the credential.

    A feed's token rides in its path, so a source with no configured label is
    named by its host — the one part of the address that opens no door.
    """
    log = PayloadLog()

    log.record("https://api.open-meteo.com/v1/forecast?latitude=40.7", {"daily": {}})
    log.record("https://cloud.example.invalid/dav/public-calendars/token-abc123?export", "ics")

    assert sorted(log.bodies()) == ["api.open-meteo.com", "cloud.example.invalid"]


def test_two_feeds_sharing_a_label_keep_their_own_bodies():
    """A second feed under a taken label takes another slot, never the first one's.

    Overwriting there would publish one feed's body as the other's, and say
    nothing about having done it.
    """
    family = "https://cloud.example.invalid/dav/public-calendars/token-abc123/basic.ics"
    work = "https://cloud.example.invalid/dav/public-calendars/token-def456/basic.ics"
    log = PayloadLog({family: "home", work: "home"})

    log.record(family, "the family feed")
    log.record(work, "the work feed")
    log.record(family, "the family feed, re-read")

    assert log.bodies() == {"home": "the family feed, re-read", "home#2": "the work feed"}
