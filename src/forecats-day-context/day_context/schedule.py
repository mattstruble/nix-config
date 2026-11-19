"""What is scheduled on one day, at one place.

Every instant comparison here goes through UTC. CPython subtracts two aware
datetimes that share a `tzinfo` object as wall-clock time, so on 2026-03-08 in
America/New_York `03:00 - 01:30` answers 1h30m when 30 minutes of the day
actually passed. Durations and overlaps are elapsed time, so they are computed
on instants.
"""

from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone

__all__ = ["UNTITLED_EVENT", "CalendarDay", "CalendarEvent", "events_overlap"]

UNTITLED_EVENT = "Untitled event"


def _instant(moment: datetime) -> datetime:
    return moment.astimezone(timezone.utc)


def events_overlap(first: "CalendarEvent", second: "CalendarEvent") -> bool:
    """Whether two events occupy any of the same elapsed time.

    All-day events have no instant extent — they are marked on a date, not
    timed within it — so they overlap nothing here.
    """
    if first.all_day or second.all_day:
        return False
    starts_before_other_ends = _instant(first.starts_at) < _instant(second.ends_at)
    other_starts_before_first_ends = _instant(second.starts_at) < _instant(first.ends_at)
    return starts_before_other_ends and other_starts_before_first_ends


@dataclass(frozen=True)
class CalendarEvent:
    """One occurrence of something on the calendar.

    `starts_at` and `ends_at` are instants. For an all-day event they are the
    local midnight boundaries of the date range, and `all_day` records that the
    source marked it by date rather than by time — a two-day all-day event is
    not a 48-hour appointment.
    """

    summary: str
    starts_at: datetime
    ends_at: datetime
    all_day: bool = False
    calendar_name: str | None = None

    def __post_init__(self) -> None:
        for label, moment in (("starts_at", self.starts_at), ("ends_at", self.ends_at)):
            if moment.tzinfo is None or moment.utcoffset() is None:
                raise ValueError(f"{label} must be timezone-aware, got {moment.isoformat()}")
        if _instant(self.ends_at) < _instant(self.starts_at):
            raise ValueError(f"event {self.summary!r} ends before it starts")

    @property
    def elapsed(self) -> timedelta:
        """Real elapsed time, which is not the wall-clock difference on a
        day with a daylight saving transition."""
        return _instant(self.ends_at) - _instant(self.starts_at)

    @property
    def starts_local_date(self) -> date:
        return self.starts_at.date()


@dataclass(frozen=True)
class CalendarDay:
    """The events on one calendar day, in local start order."""

    day: date
    timezone: str
    events: tuple[CalendarEvent, ...] = ()

    def __post_init__(self) -> None:
        if not self.timezone.strip():
            raise ValueError("timezone must name the zone the day is bounded by")
        if not isinstance(self.events, tuple):
            raise ValueError("events must be a tuple so a held day cannot be mutated")

    def __len__(self) -> int:
        return len(self.events)

    @property
    def timed_events(self) -> tuple[CalendarEvent, ...]:
        return tuple(event for event in self.events if not event.all_day)

    @property
    def overlaps(self) -> tuple[tuple[CalendarEvent, CalendarEvent], ...]:
        """Every pair of timed events that cannot both be attended."""
        timed = self.timed_events
        return tuple(
            (first, second)
            for index, first in enumerate(timed)
            for second in timed[index + 1 :]
            if events_overlap(first, second)
        )
