"""The Google Events API fallback, exercised without an OAuth client.

The service object is injected, so these tests hold a fake that answers the
way `events().list(...).execute()` answers. What they are really checking is
the claim the fallback rests on: that `singleEvents=true` is what is sent,
because that is the flag that moves recurrence expansion to Google.
"""

from datetime import date

from googleapiclient.errors import HttpError

from day_context import FailureKind, Fetched
from day_context.schedule import CalendarDay
from day_context.schedule_google_events import GoogleEventsCalendarProvider

DAY = date(2026, 3, 8)


class StatusOnly:
    """The two attributes `googleapiclient.errors.HttpError` reads off a response."""

    def __init__(self, status: int):
        self.status = status
        self.reason = {401: "Unauthorized", 429: "Too Many Requests"}[status]


class FakeRequest:
    def __init__(self, payload=None, error=None):
        self._payload, self._error = payload, error

    def execute(self):
        if self._error is not None:
            raise self._error
        return self._payload


class FakeEvents:
    def __init__(self, payload=None, error=None):
        self.parameters: dict | None = None
        self._request = FakeRequest(payload, error)

    def list(self, **parameters):
        self.parameters = parameters
        return self._request


class FakeService:
    def __init__(self, payload=None, error=None):
        self.events_resource = FakeEvents(payload, error)

    def events(self):
        return self.events_resource


def provider_for(payload=None, error=None) -> tuple[GoogleEventsCalendarProvider, FakeService]:
    service = FakeService(payload, error)
    return GoogleEventsCalendarProvider(service), service


def items(*entries: dict) -> dict:
    return {"items": list(entries)}


TIMED = {
    "summary": "Standup",
    "start": {"dateTime": "2026-03-08T09:30:00-05:00"},
    "end": {"dateTime": "2026-03-08T10:00:00-05:00"},
}
ALL_DAY = {
    "summary": "Anniversary",
    "start": {"date": "2026-03-08"},
    "end": {"date": "2026-03-09"},
}


def test_the_request_asks_google_to_expand_recurrences(new_york):
    provider, service = provider_for(items())

    provider.fetch_schedule(new_york, DAY)

    assert service.events_resource.parameters["singleEvents"] is True
    assert service.events_resource.parameters["orderBy"] == "startTime"
    assert service.events_resource.parameters["timeZone"] == "America/New_York"


def test_a_timed_entry_and_an_all_day_entry_are_not_the_same_kind_of_thing(new_york):
    provider, _ = provider_for(items(TIMED, ALL_DAY))

    day = provider.fetch_schedule(new_york, DAY).value

    timed, all_day = day.events
    assert (timed.summary, timed.all_day) == ("Standup", False)
    assert (all_day.summary, all_day.all_day) == ("Anniversary", True)
    assert timed.starts_at.utcoffset().total_seconds() == -5 * 3600


def test_a_day_google_returns_nothing_for_is_an_empty_day_not_a_failure(new_york):
    provider, _ = provider_for(items())

    outcome = provider.fetch_schedule(new_york, DAY)

    assert isinstance(outcome, Fetched)
    assert outcome.value == CalendarDay(day=DAY, timezone=new_york.timezone)


def test_a_revoked_refresh_token_is_named_as_a_credential_problem(new_york):
    provider, _ = provider_for(error=HttpError(StatusOnly(401), b"{}"))

    outcome = provider.fetch_schedule(new_york, DAY)

    assert not isinstance(outcome, Fetched)
    assert outcome.kind is FailureKind.UNAUTHORIZED
    assert "401" in outcome.reason


def test_a_quota_refusal_is_a_different_reason_from_a_credential_one(new_york):
    provider, _ = provider_for(error=HttpError(StatusOnly(429), b"{}"))

    assert provider.fetch_schedule(new_york, DAY).kind is FailureKind.REJECTED


def test_a_socket_that_never_connected_is_a_failure_not_an_empty_day(new_york):
    provider, _ = provider_for(error=OSError("[Errno 61] Connection refused"))

    outcome = provider.fetch_schedule(new_york, DAY)

    assert outcome.kind is FailureKind.UNREACHABLE
    assert "Connection refused" in outcome.reason


def test_the_fallback_satisfies_the_same_contract_as_the_chosen_provider(new_york):
    provider, _ = provider_for(items(TIMED))

    assert provider.name == "google-events-api"
    assert isinstance(provider.fetch_schedule(new_york, DAY), Fetched)
