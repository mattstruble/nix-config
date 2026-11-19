"""Assembling the answer: given a date and a place, what was the day like."""

from dataclasses import dataclass, field
from datetime import date, datetime, timezone

from .contracts import (
    CalendarProvider,
    Fetched,
    HolidayProvider,
    Location,
    ProviderFailure,
    WeatherProvider,
)
from .observances import HolidayDay
from .schedule import CalendarDay
from .weather import WeatherDay

__all__ = ["DayContext", "gather_day_context"]


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


@dataclass(frozen=True)
class DayContext:
    """One day, as far as this module is able to say what it was.

    Each section is either a `Fetched` value or a `ProviderFailure`. A section
    that came back empty and a section that could not be read are therefore
    different objects, and a caller that renders an empty one is making a
    claim it can support.
    """

    day: date
    location: Location
    weather: Fetched[WeatherDay] | ProviderFailure
    schedule: Fetched[CalendarDay] | ProviderFailure
    observances: Fetched[HolidayDay] | ProviderFailure
    assembled_at: datetime = field(default_factory=_utc_now)

    def __post_init__(self) -> None:
        if self.assembled_at.tzinfo is None or self.assembled_at.utcoffset() is None:
            raise ValueError("assembled_at must be timezone-aware")

    @property
    def failures(self) -> tuple[ProviderFailure, ...]:
        return tuple(
            section
            for section in (self.weather, self.schedule, self.observances)
            if isinstance(section, ProviderFailure)
        )

    @property
    def is_complete(self) -> bool:
        return not self.failures

    @property
    def sources(self) -> dict[str, str]:
        """Where each section came from — failures included, so the record of
        a partial day names what did not answer."""
        return {
            section: (value.source if isinstance(value, Fetched) else f"{value.source} (failed)")
            for section, value in (
                ("weather", self.weather),
                ("schedule", self.schedule),
                ("observances", self.observances),
            )
        }


def gather_day_context(
    day: date,
    location: Location,
    weather: WeatherProvider,
    calendar: CalendarProvider,
    holidays: HolidayProvider,
    assembled_at: datetime | None = None,
) -> DayContext:
    """Ask every provider and keep whatever it said.

    Nothing is caught here. A provider that cannot reach its upstream returns
    a `ProviderFailure`; a provider that raises has a bug, and turning that
    into a quiet failure would be exactly the silence this module rules out.
    """
    return DayContext(
        day=day,
        location=location,
        weather=weather.fetch_weather(location, day),
        schedule=calendar.fetch_schedule(location, day),
        observances=holidays.fetch_observances(location, day),
        assembled_at=assembled_at or _utc_now(),
    )
