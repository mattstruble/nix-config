"""The refusal and staleness types have to be honest or the pipeline is."""

from datetime import UTC, datetime

import pytest

from forecats_pipeline.contracts import PipelineRefusal, Staleness


def test_a_refusal_must_name_its_cause():
    with pytest.raises(ValueError, match="must name its cause"):
        PipelineRefusal(stage="weather", reason="   ")


def test_staleness_needs_a_zone_so_ages_are_comparable():
    with pytest.raises(ValueError, match="timezone-aware"):
        Staleness(rendered_at=datetime(2026, 11, 18, 3, 0), age_hours=1.0)


def test_staleness_cannot_be_negative():
    with pytest.raises(ValueError, match="cannot be negative"):
        Staleness(rendered_at=datetime(2026, 11, 18, 3, 0, tzinfo=UTC), age_hours=-1.0)


def _weather(**over):
    from forecats_pipeline.contracts import WeatherToday

    base = dict(
        summary="overcast",
        temperature_high_c=4.0,
        temperature_low_c=-2.0,
        precipitation_mm=0.0,
        precipitation_probability_pct=10,
        is_daylight_at_panel_time=True,
        source="open-meteo",
        fetched_at=datetime(2026, 11, 18, 3, 0, tzinfo=UTC),
    )
    return WeatherToday(**{**base, **over})


def test_weather_must_say_when_it_was_measured():
    with pytest.raises(ValueError, match="freshness proof"):
        _weather(fetched_at=datetime(2026, 11, 18, 3, 0))


def test_dry_means_the_source_said_so_not_that_data_is_missing():
    assert _weather(precipitation_mm=0.0).is_dry is True
    assert _weather(precipitation_mm=0.3).is_dry is False


def test_a_day_cannot_have_silently_lost_its_weather():
    """The sunny-picture-on-a-rainy-day guard, enforced at construction."""
    from datetime import date

    from forecats_pipeline.contracts import DayContext

    with pytest.raises(ValueError, match="stale sky gets rendered silently"):
        DayContext(for_day=date(2026, 11, 18), timezone="America/New_York", weather=None)

    ok = DayContext(
        for_day=date(2026, 11, 18),
        timezone="America/New_York",
        weather=None,
        weather_refusals=("open-meteo: no route to host",),
    )
    assert ok.weather_refusals


def test_a_day_cannot_show_a_schedule_it_failed_to_read():
    """The calendar half of the same guard: a dead feed is never an empty day."""
    from datetime import date

    from forecats_pipeline.contracts import DayContext, Occasion

    with pytest.raises(ValueError, match="could not be read has no occasions"):
        DayContext(
            for_day=date(2026, 11, 18),
            timezone="America/New_York",
            weather=None,
            occasions=(Occasion("Standup", all_day=False),),
            weather_refusals=("open-meteo: unreachable: down",),
            calendar_refusals=("ics-feed: unreachable: down",),
        )
