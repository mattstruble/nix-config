"""A Google Calendar ICS feed as the calendar source.

Chosen over the Google Events API because the recurrence expansion happens
here, in code this repository owns and tests, rather than on a Google server
that answers for the daylight saving and month-end cases and cannot be asked
how it answered them. See A-B-PROVIDERS.md.
"""

from datetime import date, datetime, time, timedelta, timezone

import icalendar
import recurring_ical_events

from .contracts import Fetched, Location, ProviderFailure
from .http_transport import HttpError, HttpFetcher, as_failure, as_malformed_failure
from .schedule import UNTITLED_EVENT, CalendarDay, CalendarEvent

__all__ = ["IcsCalendarProvider"]


def _wall_clock(moment: datetime, zone: timezone) -> datetime:
    """Re-read an instant in `zone`, so the local time is one that existed.

    `recurring_ical_events` expands a rule in nominal local time and hands the
    nominal value back. A weekly 02:30 occurrence landing on the day the clock
    jumps 02:00 to 03:00 therefore arrives as 02:30, which is a wall clock
    reading nobody can look at. `astimezone` short-circuits when the zone is
    already the one attached, so the trip goes through UTC.
    """
    return moment.astimezone(timezone.utc).astimezone(zone)


def _is_date_only(value: object) -> bool:
    return isinstance(value, date) and not isinstance(value, datetime)


def _is_datetime(value: object) -> bool:
    return isinstance(value, datetime)


def _as_instant(moment: datetime) -> datetime:
    return moment.astimezone(timezone.utc)


def _attach_zone(value: datetime, zone: timezone) -> datetime:
    """A floating iCalendar time means "the local time where we are"."""
    return value if value.tzinfo else value.replace(tzinfo=zone)


def _resolve_pair(starts: datetime, ends: datetime, zone: timezone) -> tuple[datetime, datetime]:
    """Turn a nominal start/end pair into two instants that are in order.

    A weekly 02:30 occurrence that lands on the day the clock jumps 02:00 to
    03:00 has a start that never happened and an end that did, so expanding it
    naively yields an event that finishes thirty minutes before it begins. The
    start is the event's identity, so it wins: the start moves to the instant
    the calendar client would show, and the end takes the length the event
    stated rather than the wall clock time it stated. Google Calendar resolves
    a stored event the same way.
    """
    real_start = _wall_clock(starts, zone)
    real_end = _wall_clock(ends, zone)
    if _as_instant(real_end) >= _as_instant(real_start):
        return real_start, real_end
    stated_length = ends.replace(tzinfo=None) - starts.replace(tzinfo=None)
    end_instant = _as_instant(real_start) + stated_length
    return real_start, end_instant.astimezone(zone)


def _event_from(
    component: icalendar.cal.Event, zone: timezone, calendar_name: str
) -> CalendarEvent:
    summary = str(component.get("SUMMARY") or UNTITLED_EVENT)
    start_value = component["DTSTART"].dt

    if _is_date_only(start_value):
        # `DTEND` on an all-day event is exclusive, so a one-day event ends at
        # the midnight that begins the next one.
        end_value = getattr(component.get("DTEND"), "dt", None)
        exclusive_end = end_value if _is_date_only(end_value) else start_value + timedelta(days=1)
        return CalendarEvent(
            summary=summary,
            starts_at=datetime.combine(start_value, time.min, tzinfo=zone),
            ends_at=datetime.combine(exclusive_end, time.min, tzinfo=zone),
            all_day=True,
            calendar_name=calendar_name,
        )

    start_instant = _attach_zone(start_value, zone)
    end_value = getattr(component.get("DTEND"), "dt", None)
    end_instant = _attach_zone(end_value, zone) if _is_datetime(end_value) else start_instant
    starts_at, ends_at = _resolve_pair(start_instant, end_instant, zone)
    return CalendarEvent(
        summary=summary,
        starts_at=starts_at,
        ends_at=ends_at,
        calendar_name=calendar_name,
    )


class IcsCalendarProvider:
    """One day of a published ICS feed.

    The feed URL is the credential: it carries a token that grants read access
    to whoever holds it, and nothing else. It is a constructor argument and is
    never read from the environment, so importing and testing this module
    needs no secret.
    """

    name = "ics-feed"

    def __init__(self, fetcher: HttpFetcher, feed_url: str, calendar_name: str = "primary") -> None:
        if not feed_url.strip():
            raise ValueError("feed_url must be the secret ICS URL of the calendar")
        self._fetcher = fetcher
        self._feed_url = feed_url
        self._calendar_name = calendar_name

    def fetch_schedule(self, location: Location, day: date) -> Fetched | ProviderFailure:
        try:
            text = self._fetcher.get_text(self._feed_url)
        except HttpError as error:
            return as_failure(self.name, error)

        try:
            calendar = icalendar.Calendar.from_ical(text)
        except (ValueError, TypeError, KeyError, AssertionError, UnicodeDecodeError) as error:
            return as_malformed_failure(self.name, f"the feed is not a calendar: {error}")

        zone = location.zone
        day_starts = datetime.combine(day, time.min, tzinfo=zone)
        day_ends = datetime.combine(day + timedelta(days=1), time.min, tzinfo=zone)
        try:
            occurrences = recurring_ical_events.of(calendar).between(day_starts, day_ends)
        except (ValueError, TypeError, KeyError) as error:
            return as_malformed_failure(self.name, f"recurrence expansion failed: {error}")

        dated = [event for event in occurrences if event.get("DTSTART") is not None]
        events = [_event_from(event, zone, self._calendar_name) for event in dated]

        # The day boundary is half-open and is ours, not the expander's: an
        # occurrence that only touches midnight at the far end belongs to the
        # next day.
        within_day = [
            event
            for event in events
            if _as_instant(event.starts_at) < _as_instant(day_ends)
            and _as_instant(event.ends_at) > _as_instant(day_starts)
        ]
        ordered = tuple(
            sorted(within_day, key=lambda event: (_as_instant(event.starts_at), event.summary))
        )
        return Fetched(
            CalendarDay(day=day, timezone=location.timezone, events=ordered),
            self.name,
            datetime.now(timezone.utc),
        )
