"""Home Assistant as the weather source.

The fixtures here are written from Home Assistant's documented `weather`
entity shape, not captured from a running instance — no token was used to
produce this suite. They prove the provider reads the documented contract and
refuses where the contract is silent; they do not prove any particular
instance serves that shape. See A-B-PROVIDERS.md.
"""

from datetime import date

import pytest

from day_context import (
    FailureKind,
    Fetched,
    HomeAssistantWeatherProvider,
    WeatherCondition,
)
from day_context.http_transport import TransportError

DAY = date(2026, 3, 8)


@pytest.fixture
def provider(stub_fetcher, fixture_json) -> HomeAssistantWeatherProvider:
    return HomeAssistantWeatherProvider(
        stub_fetcher(payload=fixture_json("home-assistant-weather-state.json")),
        base_url="http://homeassistant.local:8123",
        token="a-token-that-is-not-a-real-one",
    )


def report(provider, location, day=DAY):
    return provider.fetch_weather(location, day).value


def test_the_documented_entity_shape_reads_as_one_day(provider, new_york):
    day = report(provider, new_york)

    assert (day.temperature_min_c, day.temperature_max_c) == (2.6, 11.4)
    assert day.condition is WeatherCondition.RAIN
    assert day.precipitation_mm == 6.4
    assert day.precipitation_probability_pct == 75
    assert day.uv_index_max == 2.1


def test_a_forecast_entry_omitting_precipitation_is_not_read_as_dry(provider, new_york):
    # The 9 March entry in the fixture carries a probability and no amount.
    # Home Assistant distinguishes the two by presence, and so does this.
    day = report(provider, new_york, date(2026, 3, 9))

    assert day.precipitation_mm is None
    assert not day.precipitation_forecast_dry
    assert day.precipitation_probability_pct == 12


def test_a_forecast_entry_that_says_zero_does_say_dry(provider, new_york):
    assert report(provider, new_york, date(2026, 3, 7)).precipitation_forecast_dry


def test_an_entity_that_publishes_no_forecast_fails_rather_than_returning_an_empty_day(
    stub_fetcher, fixture_json, new_york
):
    provider = HomeAssistantWeatherProvider(
        stub_fetcher(payload=fixture_json("home-assistant-weather-no-forecast.json")),
        base_url="http://homeassistant.local:8123",
        token="a-token",
    )

    outcome = provider.fetch_weather(new_york, DAY)

    assert not isinstance(outcome, Fetched)
    assert outcome.kind is FailureKind.UNSUPPORTED
    assert "no forecast attribute" in outcome.reason


def test_a_forecast_that_does_not_reach_the_day_says_so(stub_fetcher, fixture_json, new_york):
    provider = HomeAssistantWeatherProvider(
        stub_fetcher(payload=fixture_json("home-assistant-weather-short-forecast.json")),
        base_url="http://homeassistant.local:8123",
        token="a-token",
    )

    outcome = provider.fetch_weather(new_york, DAY)

    assert outcome.kind is FailureKind.NO_DATA
    assert "does not reach 2026-03-08" in outcome.reason


def test_a_revoked_token_is_reported_as_a_credential_problem(stub_fetcher, new_york):
    provider = HomeAssistantWeatherProvider(
        stub_fetcher(error=TransportError("http://x/api/states/weather.h", "Unauthorized", 401)),
        base_url="http://homeassistant.local:8123",
        token="expired",
    )

    assert provider.fetch_weather(new_york, DAY).kind is FailureKind.UNAUTHORIZED


def test_the_token_travels_as_a_bearer_header(stub_fetcher, fixture_json, new_york):
    feed = stub_fetcher(payload=fixture_json("home-assistant-weather-state.json"))
    HomeAssistantWeatherProvider(feed, "http://ha.local:8123", "a-token").fetch_weather(
        new_york, DAY
    )

    assert feed.requests[-1][1] == {"Authorization": "Bearer a-token"}


def test_a_blank_token_is_refused_before_anything_is_asked_of_the_network(stub_fetcher):
    with pytest.raises(ValueError, match="token"):
        HomeAssistantWeatherProvider(stub_fetcher(), "http://ha.local:8123", "   ")


def test_an_entity_state_with_no_attributes_is_malformed_not_empty(stub_fetcher, new_york):
    provider = HomeAssistantWeatherProvider(
        stub_fetcher(payload={"entity_id": "weather.h", "state": "unknown"}),
        base_url="http://ha.local:8123",
        token="a-token",
    )

    assert provider.fetch_weather(new_york, DAY).kind is FailureKind.MALFORMED
