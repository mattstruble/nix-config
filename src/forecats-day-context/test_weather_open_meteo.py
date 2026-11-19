"""Open-Meteo as the weather source.

`fixtures/open-meteo-new-york.json` is a response captured from the live API
on 2026-11-16 for the coordinates this suite calls New York. It is used as
returned, so the shape under test is the shape that arrives.
"""

from datetime import date
from urllib.parse import parse_qs, urlparse

import pytest

from day_context import (
    FailureKind,
    Fetched,
    Location,
    OpenMeteoWeatherProvider,
    WeatherCondition,
    WeatherDay,
)
from day_context.http_transport import TransportError

CAPTURED_FIRST_DAY = date(2026, 11, 16)
CAPTURED_DAYS = ("2026-11-16", "2026-11-17", "2026-11-18")


@pytest.fixture
def provider(stub_fetcher, fixture_json) -> OpenMeteoWeatherProvider:
    return OpenMeteoWeatherProvider(stub_fetcher(payload=fixture_json("open-meteo-new-york.json")))


def report(provider, location) -> WeatherDay:
    return provider.fetch_weather(location, CAPTURED_FIRST_DAY).value


def test_the_captured_response_reads_as_one_day(provider, new_york):
    day = report(provider, new_york)

    assert day.day == CAPTURED_FIRST_DAY
    assert (day.temperature_min_c, day.temperature_max_c) == (2.1, 14.0)
    assert day.condition is WeatherCondition.OVERCAST
    assert (day.sunrise.hour, day.sunrise.minute) == (6, 44)
    assert day.sunrise.tzinfo is not None


def test_a_zero_from_the_api_means_dry_rather_than_unknown(provider, new_york):
    day = report(provider, new_york)

    # Open-Meteo answers a dry day with 0.0 and has been observed never to
    # answer with null, so "dry" and "unanswered" are only separable if a
    # missing row is refused rather than defaulted.
    assert day.precipitation_mm == 0.0
    assert day.precipitation_forecast_dry
    assert day.precipitation_probability_pct == 1


def test_the_answer_carries_the_source_and_the_moment_it_was_read(provider, new_york):
    outcome = provider.fetch_weather(new_york, CAPTURED_FIRST_DAY)

    assert isinstance(outcome, Fetched)
    assert outcome.source == "open-meteo"
    assert outcome.fetched_at.tzinfo is not None


@pytest.mark.parametrize("day", CAPTURED_DAYS)
def test_every_captured_day_is_addressable(provider, new_york, day):
    assert provider.fetch_weather(
        new_york, date.fromisoformat(day)
    ).value.day == date.fromisoformat(day)


def test_a_day_the_response_does_not_contain_fails_rather_than_reading_as_dry(provider, new_york):
    outcome = provider.fetch_weather(new_york, date(2026, 11, 20))

    assert not isinstance(outcome, Fetched)
    assert outcome.kind is FailureKind.NO_DATA
    assert "2026-11-20" in outcome.reason


def test_a_response_with_no_daily_block_fails_rather_than_reading_as_empty(
    stub_fetcher, new_york, fixture_json
):
    provider = OpenMeteoWeatherProvider(
        stub_fetcher(payload=fixture_json("open-meteo-bad-request.json"))
    )

    outcome = provider.fetch_weather(new_york, CAPTURED_FIRST_DAY)

    assert outcome.kind is FailureKind.MALFORMED


def test_a_refused_connection_is_a_failure_with_the_reason(
    stub_fetcher, new_york, connection_refused
):
    provider = OpenMeteoWeatherProvider(stub_fetcher(error=connection_refused))

    outcome = provider.fetch_weather(new_york, CAPTURED_FIRST_DAY)

    assert outcome.kind is FailureKind.UNREACHABLE
    assert "Connection refused" in outcome.reason


def test_a_rejected_request_carries_the_servers_reason(stub_fetcher, new_york):
    provider = OpenMeteoWeatherProvider(
        stub_fetcher(
            error=TransportError(
                "https://api.open-meteo.com/v1/forecast",
                "Forecast days is invalid. Allowed range 0 to 16. Given 17.",
                400,
            )
        )
    )

    outcome = provider.fetch_weather(new_york, CAPTURED_FIRST_DAY)

    assert outcome.kind is FailureKind.REJECTED
    assert outcome.reason.startswith("Forecast days is invalid")


def test_a_day_outside_the_api_window_is_refused_with_the_servers_reason(
    stub_fetcher, fixture_json, new_york
):
    """Captured live: asking past the 16-day horizon is a 400 that names the
    window, not a response with nothing in it."""
    feed = stub_fetcher(
        error=TransportError(
            "https://api.open-meteo.com/v1/forecast",
            fixture_json("open-meteo-window-past-horizon.json")["reason"],
            400,
        )
    )

    outcome = OpenMeteoWeatherProvider(feed).fetch_weather(new_york, date(2027, 6, 1))

    assert outcome.kind is FailureKind.REJECTED
    assert "out of allowed range" in outcome.reason


def test_the_request_asks_for_the_day_and_the_clock_it_is_in(stub_fetcher, new_york, fixture_json):
    feed = stub_fetcher(payload=fixture_json("open-meteo-new-york.json"))
    OpenMeteoWeatherProvider(feed).fetch_weather(new_york, CAPTURED_FIRST_DAY)

    query = parse_qs(urlparse(feed.requests[-1][0]).query)
    assert query["timezone"] == ["America/New_York"]
    assert query["start_date"] == ["2026-11-16"]
    assert query["end_date"] == ["2026-11-16"]


def test_a_day_that_arrives_without_a_temperature_is_not_a_day_of_unknown_warmth(
    stub_fetcher, new_york
):
    temperatureless = {
        "daily": {
            "time": ["2026-11-16"],
            "temperature_2m_max": [None],
            "temperature_2m_min": [None],
            "precipitation_sum": [0.0],
        }
    }
    provider = OpenMeteoWeatherProvider(stub_fetcher(payload=temperatureless))

    outcome = provider.fetch_weather(new_york, CAPTURED_FIRST_DAY)

    assert outcome.kind is FailureKind.NO_DATA


def test_the_coordinates_asked_for_are_the_ones_the_place_carries(stub_fetcher, fixture_json):
    feed = stub_fetcher(payload=fixture_json("open-meteo-new-york.json"))
    tokyo = Location("Tokyo", 35.6895, 139.6917, "Asia/Tokyo")

    OpenMeteoWeatherProvider(feed).fetch_weather(tokyo, CAPTURED_FIRST_DAY)

    query = parse_qs(urlparse(feed.requests[-1][0]).query)
    assert (query["latitude"], query["longitude"]) == (["35.6895"], ["139.6917"])
