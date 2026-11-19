"""The guards on the domain values: what a held value is known to satisfy."""

from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from day_context import (
    CalendarDay,
    CalendarEvent,
    FailureKind,
    Fetched,
    HolidayDay,
    Location,
    Observance,
    ObservanceKind,
    ProviderFailure,
    WeatherCondition,
    WeatherDay,
    events_overlap,
    weather_condition_from_wmo,
)

NEW_YORK = ZoneInfo("America/New_York")
STAMP = datetime(2026, 3, 8, 12, 0, tzinfo=timezone.utc)


def event(summary: str, starts: datetime, ends: datetime, all_day: bool = False) -> CalendarEvent:
    return CalendarEvent(summary=summary, starts_at=starts, ends_at=ends, all_day=all_day)


def at(hour: int, minute: int = 0) -> datetime:
    return datetime(2026, 3, 8, hour, minute, tzinfo=NEW_YORK)


def test_a_place_without_a_useable_clock_is_not_a_place():
    with pytest.raises(ValueError, match="IANA timezone"):
        Location("Nowhere", 0.0, 0.0, "Mars/Olympus_Mons")


@pytest.mark.parametrize("latitude", [90.1, -90.1])
def test_a_coordinate_off_the_globe_is_rejected(latitude):
    with pytest.raises(ValueError, match="latitude"):
        Location("Edge", latitude, 0.0, "America/New_York")


def test_a_blank_place_name_is_not_a_name():
    with pytest.raises(ValueError, match="name"):
        Location("   ", 0.0, 0.0, "America/New_York")


def test_a_weather_day_cannot_have_the_low_above_the_high():
    with pytest.raises(ValueError, match="temperature_min_c"):
        WeatherDay(date(2026, 3, 8), WeatherCondition.CLEAR, 12.0, 9.0)


def test_a_probability_outside_a_percent_is_not_a_probability():
    with pytest.raises(ValueError, match="precipitation_probability_pct"):
        WeatherDay(
            date(2026, 3, 8), WeatherCondition.RAIN, 1.0, 2.0, precipitation_probability_pct=101
        )


def test_zero_millimetres_is_a_forecast_of_dry_and_none_is_no_forecast():
    dry = WeatherDay(date(2026, 3, 8), WeatherCondition.CLEAR, 1.0, 2.0, precipitation_mm=0.0)
    unknown = WeatherDay(
        date(2026, 3, 8), WeatherCondition.UNKNOWN, 1.0, 2.0, precipitation_mm=None
    )

    assert dry.precipitation_forecast_dry
    assert not unknown.precipitation_forecast_dry
    assert unknown.precipitation_mm is None


def test_a_sky_the_source_did_not_name_is_not_assumed_clear():
    assert weather_condition_from_wmo(None) is WeatherCondition.UNKNOWN
    assert weather_condition_from_wmo(4677) is WeatherCondition.UNKNOWN
    assert weather_condition_from_wmo(95) is WeatherCondition.THUNDERSTORM


def test_an_event_cannot_end_before_it_starts():
    with pytest.raises(ValueError, match="ends before it starts"):
        event("Impossible", at(15), at(14))


def test_an_event_without_a_clock_is_not_an_instant():
    with pytest.raises(ValueError, match="timezone-aware"):
        CalendarEvent("Floating", datetime(2026, 3, 8, 9), datetime(2026, 3, 8, 10))


def test_elapsed_time_on_the_transition_day_is_measured_in_instants():
    shift = event("Overnight", at(1), at(3, 30))

    # 01:00 EST to 03:30 EDT. Subtracting the two datetimes answers two and a
    # half hours because they share a tzinfo object; the day only lasted an
    # hour and a half.
    assert shift.elapsed == timedelta(hours=1, minutes=30)
    assert shift.ends_at - shift.starts_at == timedelta(hours=2, minutes=30)


def test_overlap_is_decided_by_instants_not_by_the_clocks_they_are_labelled_with():
    to_kyoto = datetime(2026, 3, 9, 9, 0, tzinfo=ZoneInfo("Asia/Tokyo"))
    to_new_york = datetime(2026, 3, 8, 19, 0, tzinfo=NEW_YORK)

    # Fourteen hours apart on two walls, the same half hour on the planet.
    call = CalendarEvent("Tokyo standup", to_kyoto, to_kyoto + timedelta(hours=1))
    shift = CalendarEvent("Night shift", to_new_york, to_new_york + timedelta(hours=1, minutes=30))

    assert events_overlap(call, shift)
    assert not events_overlap(call, event("Later", at(9), at(10)))


def test_all_day_events_do_not_overlap_anything_because_they_have_no_hours():
    all_day = event("Trip", at(0), at(0) + timedelta(days=2), all_day=True)
    timed = event("Meeting", at(9), at(10))

    assert not events_overlap(all_day, timed)


def test_a_day_lists_the_pairs_that_cannot_both_be_attended():
    day = CalendarDay(
        date(2026, 3, 8),
        "America/New_York",
        (
            event("A", at(9), at(10)),
            event("B", at(9, 30), at(11)),
            event("C", at(14), at(15)),
            event("D", at(14, 30), at(15, 30)),
        ),
    )

    assert [(first.summary, second.summary) for first, second in day.overlaps] == [
        ("A", "B"),
        ("C", "D"),
    ]


def test_a_held_day_cannot_be_reordered_by_whoever_holds_it():
    with pytest.raises(ValueError, match="tuple"):
        CalendarDay(date(2026, 3, 8), "America/New_York", [event("A", at(9), at(10))])


def test_a_failure_must_say_why():
    with pytest.raises(ValueError, match="reason"):
        ProviderFailure("ics-feed", FailureKind.UNREACHABLE, "")


def test_a_value_must_say_where_it_came_from():
    with pytest.raises(ValueError, match="source"):
        Fetched(WeatherDay(date(2026, 3, 8), WeatherCondition.CLEAR, 1.0, 2.0), "", STAMP)


def test_a_value_cannot_claim_it_was_read_at_a_time_without_a_clock():
    with pytest.raises(ValueError, match="timezone-aware"):
        Fetched(
            WeatherDay(date(2026, 3, 8), WeatherCondition.CLEAR, 1.0, 2.0),
            "open-meteo",
            datetime(2026, 3, 8, 12, 0),
        )


def test_a_named_day_records_which_rule_set_named_it():
    holiday = HolidayDay(
        date(2026, 7, 3),
        "US",
        (Observance("Independence Day", date(2026, 7, 3), ObservanceKind.PUBLIC_HOLIDAY),),
    )

    assert holiday.is_holiday
    assert HolidayDay(date(2026, 7, 4), "US").is_holiday is False
