"""Merging calendar feeds must survive one feed being wrong."""

from datetime import UTC, date, datetime
from types import SimpleNamespace

from conftest import DAY, FEED_URL, StubFeed
from day_context import Fetched, FailureKind, Location, ProviderFailure
from day_context.http_transport import TransportError
from day_context.schedule_ics import IcsCalendarProvider
from forecats_pipeline.calendar_feeds import MultiFeedCalendarProvider, upcoming_occasions

LOCATION = Location("home", 40.7128, -74.006, "America/New_York")

WHEN = datetime(2026, 11, 18, 7, 30, tzinfo=UTC)
DIWALI_ICS = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//x//x//EN\r\n"
    "BEGIN:VEVENT\r\nUID:diwali@x\r\nDTSTART;VALUE=DATE:20261108\r\n"
    "SUMMARY:Diwali/Deepavali\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
)
US_ICS = (
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//x//x//EN\r\n"
    "BEGIN:VEVENT\r\nUID:us@x\r\nDTSTART;VALUE=DATE:20261111\r\n"
    "SUMMARY:Veterans Day\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
)


class DeadFeed:
    def __init__(self, text: str = "") -> None:
        self._text = text

    def get_text(self, url: str, headers: dict | None = None) -> str:
        raise TransportError(url, "connection refused")


def provider(feeds, answers: dict[str, str]):
    """A multi-feed provider whose feeds answer from a dict, or explode."""
    def factory(fetcher, url):
        return IcsCalendarProvider(StubFeed(text=answers[url]) if url in answers else DeadFeed(), url)

    return MultiFeedCalendarProvider(StubFeed(text=""), feeds, provider_factory=factory)


def new_york(new_york):
    return new_york


def test_two_feeds_answer_as_one_day(new_york):
    feeds = (("indian", "ics://indian"), ("us", "ics://us"))
    merged = provider(feeds, {"ics://indian": DIWALI_ICS, "ics://us": US_ICS})

    answer = merged.fetch_schedule(new_york, date(2026, 11, 8))

    titles = {event.summary for event in answer.value.events}
    assert "Diwali/Deepavali" in titles
    assert answer.source == "indian+us"


def test_a_dead_feed_does_not_blank_the_day_the_other_feeds_knew_about(new_york):
    feeds = (("indian", "ics://indian"), ("household", "ics://dead"))
    merged = provider(feeds, {"ics://indian": DIWALI_ICS})

    answer = merged.fetch_schedule(new_york, date(2026, 11, 8))

    assert {event.summary for event in answer.value.events} == {"Diwali/Deepavali"}


def test_a_dead_feed_is_named_rather_than_mixed_into_an_empty_day(new_york):
    """A festival feed broken for a month turns a calendar into decoration."""
    feeds = (("indian", "ics://indian"), ("household", "ics://dead"))
    merged = provider(feeds, {"ics://indian": DIWALI_ICS})

    source = merged.fetch_schedule(new_york, date(2026, 11, 8)).source

    assert "1of2" in source and "household" in source


def test_when_every_feed_is_down_that_is_a_failure_and_not_an_empty_day(new_york):
    feeds = (("household", "ics://dead"), ("us", "ics://deader"))
    merged = provider(feeds, {})

    answer = merged.fetch_schedule(new_york, date(2026, 11, 8))

    assert isinstance(answer, ProviderFailure)
    assert "no calendar feed answered" in answer.reason


def test_no_feeds_at_all_is_a_mistake_not_a_quiet_calendar():
    import pytest

    with pytest.raises(ValueError, match="no feeds"):
        MultiFeedCalendarProvider(StubFeed(text=""), ())


class CountdownProvider:
    """Answers some days and refuses others, to test what a lookahead tolerates."""

    name = "countdown"

    def __init__(self, events: dict, fails: tuple = ()) -> None:
        self._events = events
        self._fails = fails

    def fetch_schedule(self, location, day):
        if day in self._fails:
            return ProviderFailure(source=self.name, kind=FailureKind.NO_DATA, reason="feed unreachable")
        events = tuple(
            SimpleNamespace(summary=title, all_day=True) for title in self._events.get(day, ())
        )
        return Fetched(
            value=SimpleNamespace(day=day, timezone="America/New_York", events=events),
            source=self.name,
            fetched_at=datetime(2026, 10, 26, tzinfo=UTC),
        )


def test_a_festival_ahead_is_counted_not_just_named():
    """The countdown is the whole point: five days means prepare, one means eve."""
    halloween = date(2026, 10, 31)
    provider = CountdownProvider({halloween: ("Halloween",)})

    upcoming = upcoming_occasions(provider, LOCATION, date(2026, 10, 26), within_days=5)

    assert upcoming == ("Halloween is in 5 days",)


def test_tomorrow_says_day_not_days():
    provider = CountdownProvider({date(2026, 10, 27): ("Halloween",)})

    assert upcoming_occasions(provider, LOCATION, date(2026, 10, 26), within_days=5) == (
        "Halloween is in 1 day",
    )


def test_a_feed_that_will_not_answer_about_the_future_is_skipped():
    """The day being rendered was already gathered; a bad lookahead is not fatal."""
    provider = CountdownProvider(
        {date(2026, 10, 28): ("Diwali",)}, fails=(date(2026, 10, 27), date(2026, 10, 29))
    )

    assert upcoming_occasions(provider, LOCATION, date(2026, 10, 26), within_days=5) == (
        "Diwali is in 2 days",
    )


def test_nothing_is_upcoming_when_the_window_is_empty():
    provider = CountdownProvider({date(2026, 12, 25): ("Christmas Day",)})

    assert upcoming_occasions(provider, LOCATION, date(2026, 10, 26), within_days=5) == ()
