"""The federal holiday rules, including the two that are usually got wrong."""

from datetime import date

from day_context import (
    Fetched,
    HolidayDay,
    Location,
    ObservanceKind,
    UnitedStatesHolidayProvider,
)

PROVIDER = UnitedStatesHolidayProvider()


def names_on(location: Location, day: date) -> list[str]:
    return [item.name for item in PROVIDER.fetch_observances(location, day).value.observances]


def test_a_holiday_on_a_sunday_moves_to_the_monday(new_york):
    assert names_on(new_york, date(2023, 1, 2)) == ["New Year's Day"]
    assert names_on(new_york, date(2023, 1, 1)) == []


def test_a_holiday_on_a_saturday_moves_back_to_the_friday(new_york):
    assert names_on(new_york, date(2026, 7, 3)) == ["Independence Day"]
    assert names_on(new_york, date(2026, 7, 4)) == []


def test_a_holiday_on_a_weekday_stands_where_it_falls(new_york):
    assert names_on(new_york, date(2026, 12, 25)) == ["Christmas Day"]


def test_the_movable_holidays_are_found_by_rule_not_by_memory(new_york):
    assert names_on(new_york, date(2026, 5, 25)) == ["Memorial Day"]
    assert names_on(new_york, date(2026, 11, 26)) == ["Thanksgiving Day"]
    assert names_on(new_york, date(2026, 9, 7)) == ["Labor Day"]
    assert names_on(new_york, date(2026, 10, 12)) == ["Columbus Day"]


def test_juneteenth_does_not_exist_before_the_year_that_made_it_one(new_york):
    assert names_on(new_york, date(2021, 6, 18)) == ["Juneteenth National Independence Day"]
    assert names_on(new_york, date(2020, 6, 19)) == []


def test_an_ordinary_day_is_answered_with_nothing_and_is_not_a_failure(new_york):
    outcome = PROVIDER.fetch_observances(new_york, date(2026, 3, 8))

    assert isinstance(outcome, Fetched)
    assert outcome.value == HolidayDay(day=date(2026, 3, 8), region="US")
    assert not outcome.value.is_holiday


def test_the_answer_names_the_rule_set_it_applied(new_york):
    outcome = PROVIDER.fetch_observances(new_york, date(2026, 11, 11))

    assert outcome.value.region == "US"
    assert outcome.value.observances[0].kind is ObservanceKind.PUBLIC_HOLIDAY
