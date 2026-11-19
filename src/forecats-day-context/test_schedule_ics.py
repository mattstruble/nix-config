"""The acceptance suite: a synthetic calendar, queried across a hard day.

`fixtures/day.ics` carries an all-day event, a weekly rule, an event that
straddles the 2026-03-08 America/New_York clock change, a weekly rule whose
nominal time stops existing on that day, two overlapping events, and a rule
that fires only in months with a 31st. Every expectation below is worked out
from the calendar rules and the timezone database, not read back out of the
library — a test that asserts whatever the expander returned would pass while
the expander was wrong.
"""

from datetime import date, timedelta

import pytest

from day_context import FailureKind, Fetched, IcsCalendarProvider, Location
from day_context.http_transport import TransportError
from day_context.schedule import CalendarDay

FEED_URL = "https://example.invalid/private-calendar.ics"


@pytest.fixture
def provider(stub_fetcher, fixture_text) -> IcsCalendarProvider:
    return IcsCalendarProvider(stub_fetcher(text=fixture_text("day.ics")), FEED_URL)


def summaries_on(provider: IcsCalendarProvider, location: Location, day: date) -> list[str]:
    return [event.summary for event in provider.fetch_schedule(location, day).value.events]


TRANSITION_DAY = date(2026, 3, 8)


def test_the_transition_day_holds_exactly_its_six_events(provider, new_york):
    assert summaries_on(provider, new_york, TRANSITION_DAY) == [
        "Two day all day trip",
        "Overnight shift across the clock change",
        "Weekly 02:30 that stops existing",
        "Weekly Sunday call",
        "Overlap A",
        "Overlap B",
    ]


def test_an_all_day_event_covers_every_date_it_spans(provider, new_york):
    events = provider.fetch_schedule(new_york, TRANSITION_DAY).value.events
    trip = next(event for event in events if event.all_day)

    # DTEND on an all-day event names the exclusive end, so a trip dated 07 to
    # 09 is on the calendar for the 7th and the 8th and not for the 9th.
    assert (trip.starts_at.date(), trip.ends_at.date()) == (date(2026, 3, 7), date(2026, 3, 9))
    assert "Two day all day trip" in summaries_on(provider, new_york, date(2026, 3, 7))
    assert "Two day all day trip" not in summaries_on(provider, new_york, date(2026, 3, 9))


def test_a_weekly_rule_fires_on_every_seventh_day(provider, new_york):
    on_sunday = summaries_on(provider, new_york, date(2026, 3, 8))
    on_monday = summaries_on(provider, new_york, date(2026, 3, 9))

    assert "Weekly Sunday call" in on_sunday
    assert "Weekly Sunday call" not in on_monday


def test_an_event_across_the_clock_change_keeps_its_real_length(provider, new_york):
    shift = next(
        event
        for event in provider.fetch_schedule(new_york, TRANSITION_DAY).value.events
        if "clock change" in event.summary
    )

    # 01:00 EST to 03:30 EDT is two and a half hours on a wall and an hour and
    # a half on the ground, because 02:00 never happened.
    assert shift.elapsed == timedelta(hours=1, minutes=30)


def test_a_recurring_time_that_stops_existing_lands_on_a_real_clock(provider, new_york):
    occurrence = next(
        event
        for event in provider.fetch_schedule(new_york, TRANSITION_DAY).value.events
        if "stops existing" in event.summary
    )

    # The rule says 02:30. On 2026-03-08 the clock goes 02:00 to 03:00, so the
    # occurrence is at the instant 02:30 would have been, which reads 03:30.
    assert occurrence.starts_at.strftime("%H:%M %Z") == "03:30 EDT"
    assert occurrence.elapsed == timedelta(minutes=30)


def test_the_same_rule_is_unmoved_on_a_week_when_0230_existed(provider, new_york):
    earlier = next(
        event
        for event in provider.fetch_schedule(new_york, date(2026, 3, 1)).value.events
        if "stops existing" in event.summary
    )

    assert earlier.starts_at.strftime("%H:%M %Z") == "02:30 EST"


def test_two_events_that_cannot_both_be_attended_are_reported_as_a_pair(provider, new_york):
    day = provider.fetch_schedule(new_york, TRANSITION_DAY).value

    assert [(first.summary, second.summary) for first, second in day.overlaps] == [
        ("Overlap A", "Overlap B")
    ]


def test_a_rule_on_the_31st_only_happens_in_the_months_that_have_one(provider, new_york):
    occurrences = [
        day.isoformat()
        for day in (date(2026, 1, 1) + timedelta(days=offset) for offset in range(365))
        if day.year == 2026
        and "Monthly thing that only fits in seven months" in summaries_on(provider, new_york, day)
    ]

    assert occurrences == [
        "2026-01-31",
        "2026-03-31",
        "2026-05-31",
        "2026-07-31",
        "2026-08-31",
        "2026-10-31",
        "2026-12-31",
    ]


@pytest.mark.parametrize("month, day_of_month", [(2, 28), (4, 30), (6, 30), (9, 30), (11, 30)])
def test_a_month_without_a_31st_is_skipped_and_not_substituted(
    provider, new_york, month, day_of_month
):
    assert summaries_on(provider, new_york, date(2026, month, day_of_month)) == []


def test_the_day_boundary_is_half_open(provider, new_york):
    assert "Tomorrow and not today" not in summaries_on(provider, new_york, TRANSITION_DAY)
    assert "Tomorrow and not today" in summaries_on(provider, new_york, date(2026, 3, 9))


def test_an_unreachable_feed_fails_rather_than_returning_an_empty_day(
    stub_fetcher, connection_refused, new_york
):
    provider = IcsCalendarProvider(stub_fetcher(error=connection_refused), FEED_URL)

    outcome = provider.fetch_schedule(new_york, TRANSITION_DAY)

    assert not isinstance(outcome, Fetched)
    assert outcome.kind is FailureKind.UNREACHABLE
    assert "Connection refused" in outcome.reason


def test_a_feed_that_is_not_a_calendar_fails_rather_than_returning_an_empty_day(
    stub_fetcher, new_york
):
    provider = IcsCalendarProvider(stub_fetcher(text="this is not an ics file"), FEED_URL)

    outcome = provider.fetch_schedule(new_york, TRANSITION_DAY)

    assert outcome.kind is FailureKind.MALFORMED


def test_a_calendar_with_no_events_is_an_empty_day_and_not_a_failure(stub_fetcher, new_york):
    empty = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//empty//EN\r\nEND:VCALENDAR\r\n"
    provider = IcsCalendarProvider(stub_fetcher(text=empty), FEED_URL)

    outcome = provider.fetch_schedule(new_york, TRANSITION_DAY)

    assert isinstance(outcome, Fetched)
    assert outcome.value == CalendarDay(day=TRANSITION_DAY, timezone=new_york.timezone)


def test_a_server_that_refuses_the_url_says_why(stub_fetcher, new_york):
    provider = IcsCalendarProvider(
        stub_fetcher(error=TransportError(FEED_URL, "Not Found", 404)), FEED_URL
    )

    outcome = provider.fetch_schedule(new_york, TRANSITION_DAY)

    assert outcome.kind is FailureKind.REJECTED
    assert outcome.reason == "Not Found"


def test_the_feed_url_is_required_because_it_is_the_credential(stub_fetcher):
    with pytest.raises(ValueError, match="feed_url"):
        IcsCalendarProvider(stub_fetcher(text=""), "   ")
