"""Gathering three answers into one day, and keeping the shape of not knowing."""

from datetime import date, datetime, timedelta, timezone

import pytest

from day_context import (
    CalendarDay,
    DayContext,
    FailureKind,
    Fetched,
    HolidayDay,
    Location,
    ProviderFailure,
    WeatherCondition,
    WeatherDay,
    gather_day_context,
)

MORNING = datetime(2026, 3, 8, 12, 0, tzinfo=timezone.utc)
DAY = date(2026, 3, 8)


class StubWeather:
    def __init__(self, outcome):
        self.name = "stub-weather"
        self._outcome = outcome

    def fetch_weather(self, location, day):
        return self._outcome


class StubCalendar:
    def __init__(self, outcome):
        self.name = "stub-calendar"
        self._outcome = outcome

    def fetch_schedule(self, location, day):
        return self._outcome


class StubHolidays:
    def __init__(self, outcome):
        self.name = "stub-holidays"
        self._outcome = outcome

    def fetch_observances(self, location, day):
        return self._outcome


def a_weather_day() -> WeatherDay:
    return WeatherDay(
        day=DAY,
        condition=WeatherCondition.RAIN,
        temperature_min_c=2.0,
        temperature_max_c=9.0,
        precipitation_mm=6.0,
    )


def gathered(value, source: str) -> Fetched:
    return Fetched(value, source, MORNING)


def failure(source: str) -> ProviderFailure:
    return ProviderFailure(source, FailureKind.UNREACHABLE, "connection refused")


@pytest.fixture
def location(new_york) -> Location:
    return new_york


def gather(weather, calendar, holidays, location) -> DayContext:
    return gather_day_context(
        DAY,
        location,
        StubWeather(weather),
        StubCalendar(calendar),
        StubHolidays(holidays),
        assembled_at=MORNING,
    )


def test_a_day_that_was_read_names_every_source_and_reads_as_complete(location):
    context = gather(
        gathered(a_weather_day(), "open-meteo"),
        gathered(CalendarDay(DAY, location.timezone), "ics-feed"),
        gathered(HolidayDay(DAY, "US"), "us-federal-rules"),
        location,
    )

    assert context.is_complete
    assert context.sources == {
        "weather": "open-meteo",
        "schedule": "ics-feed",
        "observances": "us-federal-rules",
    }


def test_a_day_with_nothing_in_it_is_complete_and_not_a_failure(location):
    context = gather(
        gathered(a_weather_day(), "open-meteo"),
        gathered(CalendarDay(DAY, location.timezone), "ics-feed"),
        gathered(HolidayDay(DAY, "US"), "us-federal-rules"),
        location,
    )

    assert context.failures == ()
    assert context.schedule.value.events == ()


def test_a_provider_that_could_not_read_the_sky_is_not_a_day_with_no_weather(location):
    context = gather(
        failure("open-meteo"),
        gathered(CalendarDay(DAY, location.timezone), "ics-feed"),
        gathered(HolidayDay(DAY, "US"), "us-federal-rules"),
        location,
    )

    assert not context.is_complete
    assert context.weather == failure("open-meteo")
    assert context.weather.reason == "connection refused"


def test_one_section_failing_leaves_the_other_two_readable(location):
    context = gather(
        gathered(a_weather_day(), "open-meteo"),
        failure("ics-feed"),
        gathered(HolidayDay(DAY, "US"), "us-federal-rules"),
        location,
    )

    assert context.weather.value.precipitation_mm == 6.0
    assert context.observances.value.region == "US"
    assert [item.source for item in context.failures] == ["ics-feed"]


def test_two_sections_failing_are_both_named(location):
    context = gather(
        failure("open-meteo"),
        failure("ics-feed"),
        gathered(HolidayDay(DAY, "US"), "us-federal-rules"),
        location,
    )

    assert {item.source for item in context.failures} == {"open-meteo", "ics-feed"}
    assert context.sources["weather"] == "open-meteo (failed)"


def test_a_failed_section_is_recorded_as_failed_so_a_partial_day_cannot_look_clean(location):
    context = gather(
        gathered(a_weather_day(), "open-meteo"),
        failure("ics-feed"),
        gathered(HolidayDay(DAY, "US"), "us-federal-rules"),
        location,
    )

    assert context.sources["schedule"] == "ics-feed (failed)"


def test_a_day_refuses_to_record_a_failure_without_a_reason(location):
    with pytest.raises(ValueError, match="must carry a reason"):
        gather(
            ProviderFailure("open-meteo", FailureKind.UNREACHABLE, "   "),
            gathered(CalendarDay(DAY, location.timezone), "ics-feed"),
            gathered(HolidayDay(DAY, "US"), "us-federal-rules"),
            location,
        )


def test_a_day_without_a_clock_is_rejected(location):
    with pytest.raises(ValueError, match="assembled_at"):
        DayContext(
            day=DAY,
            location=location,
            weather=gathered(a_weather_day(), "open-meteo"),
            schedule=gathered(CalendarDay(DAY, location.timezone), "ics-feed"),
            observances=gathered(HolidayDay(DAY, "US"), "us-federal-rules"),
            assembled_at=datetime(2026, 3, 8, 12, 0),
        )


def test_a_gathered_day_stamps_itself_when_the_caller_does_not(location):
    context = gather_day_context(
        DAY,
        location,
        StubWeather(failure("open-meteo")),
        StubCalendar(failure("ics-feed")),
        StubHolidays(failure("us-federal-rules")),
    )

    assert context.assembled_at <= datetime.now(timezone.utc) + timedelta(seconds=5)
    assert context.assembled_at.tzinfo is not None
