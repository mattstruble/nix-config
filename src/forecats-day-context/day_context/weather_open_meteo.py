"""Open-Meteo as the weather source.

Chosen over a Home Assistant proxy on three measured axes, recorded in
A-B-PROVIDERS.md: it answers for 16 days ahead with no credential, it costs
zero packages beyond the standard library, and its contract is fixed rather
than whatever integration the host happens to have configured.
"""

from datetime import date, datetime
from urllib.parse import urlencode

from .contracts import FailureKind, Fetched, Location, ProviderFailure
from .http_transport import HttpError, HttpFetcher, as_failure, as_malformed_failure
from .weather import WeatherDay, weather_condition_from_wmo

__all__ = ["OpenMeteoWeatherProvider"]

_FORECAST_VARIABLES = (
    "weather_code",
    "temperature_2m_max",
    "temperature_2m_min",
    "precipitation_sum",
    "precipitation_probability_max",
    "precipitation_hours",
    "uv_index_max",
    "sunrise",
    "sunset",
)

# Open-Meteo answers a start_date outside [today - 92 days, today + 16 days]
# with HTTP 400 and a `reason`, so a day outside the window is a failure the
# provider surfaces rather than a day it agrees to describe.


class OpenMeteoWeatherProvider:
    """Weather from api.open-meteo.com. No key, no account, no scope."""

    name = "open-meteo"

    def __init__(
        self,
        fetcher: HttpFetcher,
        endpoint: str = "https://api.open-meteo.com/v1/forecast",
    ) -> None:
        self._fetcher = fetcher
        self._endpoint = endpoint

    def fetch_weather(self, location: Location, day: date) -> Fetched | ProviderFailure:
        url = f"{self._endpoint}?{self._query(location, day)}"
        try:
            payload = self._fetcher.get_json(url)
        except HttpError as error:
            return as_failure(self.name, error)

        daily = payload.get("daily")
        if not isinstance(daily, dict):
            return as_malformed_failure(self.name, "response carries no `daily` block")
        times = daily.get("time")
        if not isinstance(times, list):
            return as_malformed_failure(self.name, "`daily.time` is not a list")

        # Absent row is a failure, never an empty day. Open-Meteo answers a
        # day it covers with 0.0 for "dry" and has no value it uses for "I do
        # not know", so a missing row silently indexed as 0.0 becomes a
        # forecast of a dry sky.
        label = day.isoformat()
        if label not in times:
            return ProviderFailure(
                self.name,
                FailureKind.NO_DATA,
                f"the response covers {len(times)} days and none of them is {label}",
            )
        index = times.index(label)

        def daily_value(field: str) -> object:
            values = daily.get(field)
            if not isinstance(values, list) or index >= len(values):
                return None
            return values[index]

        def number(field: str) -> float | None:
            value = daily_value(field)
            return float(value) if isinstance(value, (int, float)) else None

        def whole(field: str) -> int | None:
            value = daily_value(field)
            return int(value) if isinstance(value, (int, float)) else None

        def moment(field: str) -> datetime | None:
            value = daily_value(field)
            if not isinstance(value, str):
                return None
            local = datetime.fromisoformat(value)
            return local.replace(tzinfo=location.zone) if local.tzinfo is None else local

        minimum = number("temperature_2m_min")
        maximum = number("temperature_2m_max")
        if minimum is None or maximum is None:
            return ProviderFailure(
                self.name,
                FailureKind.NO_DATA,
                f"{label} arrived without a temperature range, so the day is not known",
            )

        report = WeatherDay(
            day=day,
            condition=weather_condition_from_wmo(whole("weather_code")),
            temperature_min_c=minimum,
            temperature_max_c=maximum,
            precipitation_mm=number("precipitation_sum"),
            precipitation_probability_pct=whole("precipitation_probability_max"),
            precipitation_hours=number("precipitation_hours"),
            uv_index_max=number("uv_index_max"),
            sunrise=moment("sunrise"),
            sunset=moment("sunset"),
        )
        return Fetched(report, self.name, datetime.now().astimezone())

    def _query(self, location: Location, day: date) -> str:
        return urlencode(
            {
                "latitude": location.latitude,
                "longitude": location.longitude,
                "timezone": location.timezone,
                "start_date": day.isoformat(),
                "end_date": day.isoformat(),
                "daily": ",".join(_FORECAST_VARIABLES),
            }
        )
