'''Several ICS feeds, answered as one day.

A household's calendar is never one URL: the family calendar, the holidays of
the country you live in, the holidays of the festivals you keep. The pipeline
takes a single `CalendarProvider`, so the merge has to happen somewhere, and
doing it here keeps `build_day_context` free of feed-counting.

Partial failure is the interesting case. A feed that is down must not blank the
day — the other feeds still know it is Diwali — and it must not pass unnoticed
either, because "the festival feed has been broken for a month" is exactly how
a wall calendar becomes decoration. So a shortfall is answered with what did
arrive, and the `source` string names what did not.
'''

from collections.abc import Callable, Sequence
from typing import Protocol

from day_context import Fetched, Location, ProviderFailure
from day_context.contracts import CalendarDay
from day_context.schedule_ics import IcsCalendarProvider
from day_context.http_transport import HttpFetcher

__all__ = ["MultiFeedCalendarProvider"]


class _Provider(Protocol):
    name: str

    def fetch_schedule(self, location: Location, day): ...


class MultiFeedCalendarProvider:
    """The union of several ICS feeds for one day.

    `feeds` are URLs, and a URL is a credential: the private calendar's address
    grants read access to whoever holds it. Labels are therefore derived from
    the tail of the URL rather than the whole of it, so a `source` string that
    reaches a provenance file cannot leak a secret address.
    """

    name = "ics-multi"

    def __init__(
        self,
        fetcher: HttpFetcher,
        feeds: Sequence[tuple[str, str]],
        provider_factory: Callable[[object, str], _Provider] = IcsCalendarProvider,
    ) -> None:
        """`feeds` is a sequence of (label, url); the label is what a refusal names."""
        if not feeds:
            raise ValueError("a calendar with no feeds knows nothing, which is not the same as empty")
        self._providers = tuple(
            (label, provider_factory(fetcher, url)) for label, url in feeds
        )

    def fetch_schedule(self, location: Location, day) -> Fetched[CalendarDay] | ProviderFailure:
        events = []
        timezone_name = ""
        answered: list[str] = []
        missing: list[str] = []
        failures: list[ProviderFailure] = []
        answers: list[Fetched] = []

        for label, provider in self._providers:
            answer = provider.fetch_schedule(location, day)
            if isinstance(answer, ProviderFailure):
                missing.append(f"{label} {answer.kind.value}")
                failures.append(answer)
                continue
            answered.append(label)
            answers.append(answer)
            timezone_name = answer.value.timezone or timezone_name
            events.extend(answer.value.events)

        if not answered:
            reasons = "; ".join(f"{f.source}: {f.reason}" for f in failures)
            return ProviderFailure(
                source=self.name,
                kind=failures[0].kind,
                reason=f"no calendar feed answered ({reasons})",
            )

        calendar_day = CalendarDay(day=day, timezone=timezone_name, events=tuple(events))
        return Fetched(
            value=calendar_day,
            source=_source(answered, missing),
            # The oldest fetch among the feeds that answered: the merged day is
            # only as fresh as its stalest contributor.
            fetched_at=min((answer.fetched_at for answer in answers)),
        )


def _source(answered: list[str], missing: list[str]) -> str:
    """Which feeds spoke, and by name, which feeds did not."""
    if not missing:
        return "+".join(answered)
    return f"{len(answered)}of{len(answered) + len(missing)} feeds, missing: {', '.join(missing)}"
