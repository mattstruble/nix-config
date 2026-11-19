"""Merging calendar feeds must survive one feed being wrong."""

from datetime import UTC, date, datetime

from conftest import DAY, FEED_URL, StubFeed
from day_context import FailureKind, ProviderFailure
from day_context.http_transport import TransportError
from day_context.schedule_ics import IcsCalendarProvider
from forecats_pipeline.calendar_feeds import MultiFeedCalendarProvider

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
