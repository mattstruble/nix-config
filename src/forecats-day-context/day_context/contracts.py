"""The vocabulary a provider implements against.

A provider never raises for conditions it cannot control. It returns either a
`Fetched` value carrying where and when it came from, or a `ProviderFailure`
carrying why it did not. An empty day is a `Fetched` value with nothing in it;
a day that could not be read is a `ProviderFailure`. The two are different
types, so no caller can confuse them by forgetting a check.
"""

from dataclasses import dataclass
from datetime import date, datetime
from enum import StrEnum
from typing import Protocol, runtime_checkable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .observances import HolidayDay
from .schedule import CalendarDay
from .weather import WeatherDay

__all__ = [
    "CalendarProvider",
    "DayContextError",
    "FailureKind",
    "Fetched",
    "HolidayProvider",
    "Location",
    "ProviderFailure",
    "WeatherProvider",
]


class DayContextError(Exception):
    """Base for every error this module raises deliberately."""


class FailureKind(StrEnum):
    """Why a provider could not answer. Distinguishes retryable from hopeless."""

    UNREACHABLE = "unreachable"
    REJECTED = "rejected"
    UNAUTHORIZED = "unauthorized"
    NO_DATA = "no_data"
    MALFORMED = "malformed"
    UNSUPPORTED = "unsupported"


@dataclass(frozen=True)
class Location:
    """A place a day can be asked about.

    The timezone is required rather than inferred: "today", and the start and
    end of every calendar day, are defined by it. A location without one
    silently inherits whatever clock the host happens to run on.
    """

    name: str
    latitude: float
    longitude: float
    timezone: str

    def __post_init__(self) -> None:
        if not self.name.strip():
            raise ValueError("name must not be blank")
        if not -90.0 <= self.latitude <= 90.0:
            raise ValueError(f"latitude must be within [-90, 90], got {self.latitude}")
        if not -180.0 <= self.longitude <= 180.0:
            raise ValueError(f"longitude must be within [-180, 180], got {self.longitude}")
        try:
            ZoneInfo(self.timezone)
        except (ZoneInfoNotFoundError, ValueError) as error:
            raise ValueError(f"{self.timezone!r} is not a resolvable IANA timezone") from error

    @property
    def zone(self) -> ZoneInfo:
        return ZoneInfo(self.timezone)


@dataclass(frozen=True)
class Fetched[T]:
    """A value that was read, with the provenance the caller has to surface."""

    value: T
    source: str
    fetched_at: datetime

    def __post_init__(self) -> None:
        if not self.source.strip():
            raise ValueError("source must name where the value came from")
        if self.fetched_at.tzinfo is None or self.fetched_at.utcoffset() is None:
            raise ValueError("fetched_at must be timezone-aware")


@dataclass(frozen=True)
class ProviderFailure:
    """A provider that could not answer, and why.

    Carrying the reason is the whole point: a blank sky on a stormy day is the
    failure this project cannot afford, so a failure must never be expressible
    as an empty value.
    """

    source: str
    kind: FailureKind
    reason: str

    def __post_init__(self) -> None:
        if not self.source.strip():
            raise ValueError("source must name what failed")
        if not self.reason.strip():
            raise ValueError(f"{self.source}: a failure must carry a reason")


@runtime_checkable
class WeatherProvider(Protocol):
    """Answers "what was the weather like on `day` at `location`"."""

    name: str

    def fetch_weather(
        self, location: Location, day: date
    ) -> Fetched[WeatherDay] | ProviderFailure: ...


@runtime_checkable
class CalendarProvider(Protocol):
    """Answers "what is scheduled on `day` at `location`"."""

    name: str

    def fetch_schedule(
        self, location: Location, day: date
    ) -> Fetched[CalendarDay] | ProviderFailure: ...


@runtime_checkable
class HolidayProvider(Protocol):
    """Answers "is `day` a named observance where `location` is"."""

    name: str

    def fetch_observances(
        self, location: Location, day: date
    ) -> Fetched[HolidayDay] | ProviderFailure: ...
