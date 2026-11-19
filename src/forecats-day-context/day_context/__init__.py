"""Given a date and a place, what was the day like.

Three questions, one value: what the sky did, what was scheduled, and whether
the day has a name where the place is. Each is answered by a provider behind a
`Protocol`, and each answer arrives as either a `Fetched` value carrying its
source and the moment it was read, or a `ProviderFailure` carrying why it did
not. Nothing here raises because an upstream was down, and nothing here can
express "I could not look" as "there was nothing".

The pipeline this package ships with is Open-Meteo for the sky, a Google
Calendar ICS feed for the schedule, and the United States federal rules for
names. The alternatives that lost that contest are in this package too, and
`A-B-PROVIDERS.md` records what was measured and which way it fell:

    HomeAssistantWeatherProvider  weather/home-assistant   -- fallback
    GoogleEventsCalendarProvider  schedule/google-events   -- fallback

The Google fallback is deliberately not imported here. It is the only provider
whose dependency closure is large enough to matter, and a fallback should not
be paid for by the pipeline that did not choose it.

This module answers "what is today". It has no opinion about what anyone does
with the answer, and no concept from downstream belongs in it.
"""

from .contracts import (
    CalendarProvider,
    DayContextError,
    FailureKind,
    Fetched,
    HolidayProvider,
    Location,
    ProviderFailure,
    WeatherProvider,
)
from .day import DayContext, gather_day_context
from .http_transport import HttpFetcher, UrllibFetcher
from .observances import HolidayDay, Observance, ObservanceKind
from .observances_united_states import UnitedStatesHolidayProvider
from .schedule import CalendarDay, CalendarEvent, events_overlap
from .schedule_ics import IcsCalendarProvider
from .weather import WeatherCondition, WeatherDay, weather_condition_from_wmo
from .weather_home_assistant import HomeAssistantWeatherProvider
from .weather_open_meteo import OpenMeteoWeatherProvider

__all__ = [
    "CalendarDay",
    "CalendarEvent",
    "CalendarProvider",
    "DayContext",
    "DayContextError",
    "FailureKind",
    "Fetched",
    "HolidayDay",
    "HolidayProvider",
    "HomeAssistantWeatherProvider",
    "HttpFetcher",
    "IcsCalendarProvider",
    "Location",
    "Observance",
    "ObservanceKind",
    "OpenMeteoWeatherProvider",
    "ProviderFailure",
    "UnitedStatesHolidayProvider",
    "UrllibFetcher",
    "WeatherCondition",
    "WeatherDay",
    "WeatherProvider",
    "events_overlap",
    "gather_day_context",
    "weather_condition_from_wmo",
]
