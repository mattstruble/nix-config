"""United States federal holidays, computed from the rule rather than a table.

The alternative — a data file of dates — is correct until the year turns and
then quietly returns nothing for January. A rule set cannot go stale, and the
rules are short enough to hold in one screen.
"""

import calendar
from collections.abc import Callable
from datetime import date, datetime, timedelta, timezone

from .contracts import Fetched, Location, ProviderFailure
from .observances import HolidayDay, Observance, ObservanceKind

__all__ = ["UnitedStatesHolidayProvider"]


def _nth_weekday(year: int, month: int, weekday: int, occurrence: int) -> date:
    first = date(year, month, 1)
    offset = (weekday - first.weekday()) % 7
    return first + timedelta(days=offset + 7 * (occurrence - 1))


def _last_weekday(year: int, month: int, weekday: int) -> date:
    last_day = calendar.monthrange(year, month)[1]
    day = date(year, month, last_day)
    return day - timedelta(days=(day.weekday() - weekday) % 7)


def _observed(day: date) -> date:
    """A federal holiday on a weekend is worked off on the adjacent weekday.

    Saturday moves back to Friday and Sunday moves forward to Monday; the day
    the nation names is not the day the building is shut.
    """
    if day.weekday() == calendar.SATURDAY:
        return day - timedelta(days=1)
    if day.weekday() == calendar.SUNDAY:
        return day + timedelta(days=1)
    return day


def _fixed(month: int, day: int) -> Callable[[int], date]:
    return lambda year: _observed(date(year, month, day))


_RULES: tuple[tuple[str, Callable[[int], date]], ...] = (
    ("New Year's Day", _fixed(1, 1)),
    ("Birthday of Martin Luther King, Jr.", lambda y: _nth_weekday(y, 1, calendar.MONDAY, 3)),
    ("Washington's Birthday", lambda y: _nth_weekday(y, 2, calendar.MONDAY, 3)),
    ("Memorial Day", lambda y: _last_weekday(y, 5, calendar.MONDAY)),
    # Juneteenth became a federal holiday on 17 June 2021; before that year the
    # rule deliberately produces nothing.
    (
        "Juneteenth National Independence Day",
        lambda y: _observed(date(y, 6, 19)) if y >= 2021 else None,
    ),
    ("Independence Day", _fixed(7, 4)),
    ("Labor Day", lambda y: _nth_weekday(y, 9, calendar.MONDAY, 1)),
    ("Columbus Day", lambda y: _nth_weekday(y, 10, calendar.MONDAY, 2)),
    ("Veterans Day", _fixed(11, 11)),
    ("Thanksgiving Day", lambda y: _nth_weekday(y, 11, calendar.THURSDAY, 4)),
    ("Christmas Day", _fixed(12, 25)),
)


class UnitedStatesHolidayProvider:
    """Federal holidays, which are the only "the day is named" facts this
    module asserts. State and religious calendars are a different rule set and
    a different provider; `HolidayDay.region` records which one answered.

    It takes no transport and reaches no network, so it can never be the
    section that fails to answer — but it can be the section that is wrong for
    the place, which is why the region travels with the answer.
    """

    name = "us-federal-rules"
    region = "US"

    def fetch_observances(self, location: Location, day: date) -> Fetched | ProviderFailure:
        names = [
            name
            for name, rule in _RULES
            if (holiday := rule(day.year)) is not None and holiday == day
        ]
        observances = tuple(
            Observance(name=name, day=day, kind=ObservanceKind.PUBLIC_HOLIDAY) for name in names
        )
        return Fetched(
            HolidayDay(day=day, region=self.region, observances=observances),
            self.name,
            datetime.now(timezone.utc),
        )
