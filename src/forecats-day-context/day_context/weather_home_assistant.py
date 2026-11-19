"""Home Assistant's REST states API as a weather source.

Kept as the named fallback for a host that already runs Home Assistant and
would rather reuse its integration than add a second sky. It is tested against
a fixture written from Home Assistant's documented entity shape, not against a
live instance — see A-B-PROVIDERS.md for what that does and does not prove.
"""

from datetime import date, datetime, timezone
from enum import StrEnum

from .contracts import FailureKind, Fetched, Location, ProviderFailure
from .http_transport import HttpError, HttpFetcher, as_failure, as_malformed_failure
from .weather import WeatherCondition, WeatherDay

__all__ = ["HomeAssistantWeatherProvider"]


# Home Assistant's `condition` attribute is one of a fixed set of strings the
# WeatherEntity contract allows; anything else is an integration inventing a
# value and becomes UNKNOWN rather than a guess.
_HA_CONDITIONS: dict[str, WeatherCondition] = {
    "clear": WeatherCondition.CLEAR,
    "cloudy": WeatherCondition.OVERCAST,
    "foggy": WeatherCondition.FOG,
    "lightning": WeatherCondition.THUNDERSTORM,
    "lightning-rainy": WeatherCondition.THUNDERSTORM,
    "partlycloudy": WeatherCondition.PARTLY_CLOUDY,
    "pouring": WeatherCondition.RAIN,
    "rainy": WeatherCondition.RAIN,
    "snowy": WeatherCondition.SNOW,
    "snowy-rainy": WeatherCondition.FREEZING_PRECIPITATION,
    "sunny": WeatherCondition.CLEAR,
}


class _ForecastPresence(StrEnum):
    ABSENT = "absent"
    EMPTY = "empty"
    NOT_COVERED = "not-covered"


class HomeAssistantWeatherProvider:
    """One day read out of a `weather.*` entity's forecast attribute.

    The token is a constructor argument and is never read from the environment:
    this module must be importable, and testable, on a machine that has no
    Home Assistant to talk to.
    """

    name = "home-assistant"

    def __init__(
        self,
        fetcher: HttpFetcher,
        base_url: str,
        token: str,
        weather_entity: str = "weather.forecast_home",
    ) -> None:
        if not token.strip():
            raise ValueError(
                "token must not be blank; a Home Assistant long-lived token is required"
            )
        self._fetcher = fetcher
        self._base_url = base_url.rstrip("/")
        self._token = token
        self._weather_entity = weather_entity

    def fetch_weather(self, location: Location, day: date) -> Fetched | ProviderFailure:
        # `location` is unused: a Home Assistant weather entity answers for the
        # house the instance is configured around, not for a coordinate.
        url = f"{self._base_url}/api/states/{self._weather_entity}"
        try:
            payload = self._fetcher.get_json(url, {"Authorization": f"Bearer {self._token}"})
        except HttpError as error:
            return as_failure(self.name, error)

        attributes = payload.get("attributes")
        if not isinstance(attributes, dict):
            return as_malformed_failure(self.name, "entity state carries no attributes")

        entry = self._entry_for(attributes.get("forecast"), day, location.zone)
        if entry is _ForecastPresence.ABSENT:
            return ProviderFailure(
                self.name,
                FailureKind.UNSUPPORTED,
                f"{self._weather_entity} publishes no forecast attribute, so this entity "
                "cannot answer for a future day",
            )
        if entry is _ForecastPresence.EMPTY:
            return ProviderFailure(
                self.name,
                FailureKind.NO_DATA,
                f"{self._weather_entity}'s forecast is empty, which is not the same as a day "
                "with nothing in it",
            )
        if entry is _ForecastPresence.NOT_COVERED:
            return ProviderFailure(
                self.name,
                FailureKind.NO_DATA,
                f"{self._weather_entity}'s forecast does not reach {day.isoformat()}",
            )

        # A key that is absent means the integration did not answer it; a key
        # that is present and 0.0 means it answered "none". Home Assistant
        # distinguishes these by presence, which is the one axis it handles
        # better than a flat array response.
        def number(key: str) -> float | None:
            value = entry.get(key)
            return float(value) if isinstance(value, (int, float)) else None

        minimum = _first_number(entry, ("templow", "temperature_min", "temperature"))
        maximum = _first_number(entry, ("temp_high", "temperature_max", "temperature"))
        condition = entry.get("condition") or attributes.get("condition")
        if minimum is None or maximum is None:
            return ProviderFailure(
                self.name,
                FailureKind.NO_DATA,
                f"{self._weather_entity} has no temperature range for {day.isoformat()}",
            )

        report = WeatherDay(
            day=day,
            condition=_HA_CONDITIONS.get(condition, WeatherCondition.UNKNOWN)
            if isinstance(condition, str)
            else WeatherCondition.UNKNOWN,
            temperature_min_c=minimum,
            temperature_max_c=maximum,
            precipitation_mm=number("precipitation"),
            precipitation_probability_pct=_whole(entry.get("precipitation_probability")),
            uv_index_max=number("uv_index"),
        )
        return Fetched(report, self.name, datetime.now().astimezone())

    def _entry_for(
        self, forecast: object, day: date, zone: timezone
    ) -> dict[str, object] | _ForecastPresence:
        if forecast is None or not isinstance(forecast, list):
            return _ForecastPresence.ABSENT
        if not forecast:
            return _ForecastPresence.EMPTY
        for entry in forecast:
            if not isinstance(entry, dict):
                continue
            stamp = entry.get("datetime")
            if isinstance(stamp, str) and _local_date(stamp, zone) == day:
                return entry
        return _ForecastPresence.NOT_COVERED


def _local_date(stamp: str, zone: timezone) -> date | None:
    """A forecast entry is stamped with an offset; the day it belongs to is the
    day where the caller is, not where the stamp's offset says."""
    try:
        return datetime.fromisoformat(stamp).astimezone(zone).date()
    except ValueError:
        return None


def _first_number(entry: dict[str, object], keys: tuple[str, ...]) -> float | None:
    for key in keys:
        value = entry.get(key)
        if isinstance(value, (int, float)):
            return float(value)
    return None


def _whole(value: object) -> int | None:
    return int(value) if isinstance(value, (int, float)) else None
