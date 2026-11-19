"""The Google Events API as the calendar source.

Kept as the named fallback. It is not imported by `day_context/__init__.py`,
so the chosen pipeline does not pay for its dependency closure; it is tested
here so that "fallback" means "runs", not "exists".

The axis that decided it: `singleEvents=true` moves recurrence expansion to a
Google server. That deletes the code that could be wrong about daylight saving
and the 31st, and with it the test that could have caught the error. See
A-B-PROVIDERS.md.
"""

from datetime import date, datetime, time, timedelta, timezone

from googleapiclient.errors import HttpError

from .contracts import FailureKind, Fetched, Location, ProviderFailure
from .schedule import UNTITLED_EVENT, CalendarDay, CalendarEvent

__all__ = ["GoogleEventsCalendarProvider"]


def _parse_moment(block: dict[str, str], zone: timezone) -> datetime:
    """Google returns `date` for an all-day entry and `dateTime` for a timed
    one; the two are not interchangeable and only one is present."""
    stamp = block.get("dateTime")
    if stamp is None:
        day = date.fromisoformat(block["date"])
        return datetime.combine(day, time.min, tzinfo=zone)
    moment = datetime.fromisoformat(stamp)
    return moment if moment.tzinfo else moment.replace(tzinfo=zone)


class GoogleEventsCalendarProvider:
    """One day read from `events.list` with `singleEvents=true`.

    The service object is injected rather than built here: obtaining one means
    an OAuth client and a refresh token, and this module has to be importable
    and testable on a machine that has neither.
    """

    name = "google-events-api"

    def __init__(self, service: object, calendar_id: str = "primary") -> None:
        self._service = service
        self._calendar_id = calendar_id

    def fetch_schedule(self, location: Location, day: date) -> Fetched | ProviderFailure:
        zone = location.zone
        day_starts = datetime.combine(day, time.min, tzinfo=zone)
        day_ends = day_starts + timedelta(days=1)
        request = self._service.events().list(  # type: ignore[attr-defined]
            calendarId=self._calendar_id,
            singleEvents=True,
            orderBy="startTime",
            timeMin=day_starts.isoformat(),
            timeMax=day_ends.isoformat(),
            timeZone=location.timezone,
        )
        try:
            response = request.execute()
        except HttpError as error:
            status = getattr(getattr(error, "resp", None), "status", None)
            kind = FailureKind.UNAUTHORIZED if status in (401, 403) else FailureKind.REJECTED
            return ProviderFailure(self.name, kind, f"events.list returned {status}")
        except (OSError, TimeoutError) as error:
            return ProviderFailure(self.name, FailureKind.UNREACHABLE, str(error))

        events = tuple(self._event_from(item, zone) for item in response.get("items", []))
        return Fetched(
            CalendarDay(day=day, timezone=location.timezone, events=events),
            self.name,
            datetime.now(timezone.utc),
        )

    def _event_from(self, item: dict[str, object], zone: timezone) -> CalendarEvent:
        start_block = item.get("start", {})
        end_block = item.get("end", {})
        all_day = "dateTime" not in start_block
        summary = item.get("summary") or UNTITLED_EVENT
        return CalendarEvent(
            summary=str(summary),
            starts_at=_parse_moment(start_block, zone),
            ends_at=_parse_moment(end_block, zone),
            all_day=all_day,
            calendar_name=str(item.get("calendarId", self._calendar_id)),
        )
