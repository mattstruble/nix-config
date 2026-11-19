"""What the sky did on one day, at one place."""

from dataclasses import dataclass
from datetime import date, datetime
from enum import StrEnum

__all__ = ["WeatherCondition", "WeatherDay", "weather_condition_from_wmo"]


class WeatherCondition(StrEnum):
    """Coarse sky condition. Deliberately not a free-text string: the caller
    has to be able to branch on it, and every provider has to agree on the set."""

    CLEAR = "clear"
    MAINLY_CLEAR = "mainly-clear"
    PARTLY_CLOUDY = "partly-cloudy"
    OVERCAST = "overcast"
    FOG = "fog"
    DRIZZLE = "drizzle"
    RAIN = "rain"
    FREEZING_PRECIPITATION = "freezing-precipitation"
    SNOW = "snow"
    THUNDERSTORM = "thunderstorm"
    UNKNOWN = "unknown"


# WMO Interpretation Code No. 4677, as Open-Meteo's `weather_code` field reports
# it. The grouping into WeatherCondition is ours; the code numbers are theirs.
_WMO_CONDITIONS: dict[int, WeatherCondition] = {
    0: WeatherCondition.CLEAR,
    1: WeatherCondition.MAINLY_CLEAR,
    2: WeatherCondition.PARTLY_CLOUDY,
    3: WeatherCondition.OVERCAST,
    45: WeatherCondition.FOG,
    48: WeatherCondition.FOG,
    51: WeatherCondition.DRIZZLE,
    53: WeatherCondition.DRIZZLE,
    55: WeatherCondition.DRIZZLE,
    56: WeatherCondition.FREEZING_PRECIPITATION,
    57: WeatherCondition.FREEZING_PRECIPITATION,
    61: WeatherCondition.RAIN,
    63: WeatherCondition.RAIN,
    65: WeatherCondition.RAIN,
    66: WeatherCondition.FREEZING_PRECIPITATION,
    67: WeatherCondition.FREEZING_PRECIPITATION,
    71: WeatherCondition.SNOW,
    73: WeatherCondition.SNOW,
    75: WeatherCondition.SNOW,
    77: WeatherCondition.SNOW,
    80: WeatherCondition.RAIN,
    81: WeatherCondition.RAIN,
    82: WeatherCondition.RAIN,
    85: WeatherCondition.SNOW,
    86: WeatherCondition.SNOW,
    95: WeatherCondition.THUNDERSTORM,
    96: WeatherCondition.THUNDERSTORM,
    99: WeatherCondition.THUNDERSTORM,
}


def weather_condition_from_wmo(code: int | None) -> WeatherCondition:
    """Map a WMO 4677 code, or report that the source did not say.

    `None` and an unmapped code both become UNKNOWN rather than CLEAR: a
    missing code is not evidence of a clear sky.
    """
    if code is None:
        return WeatherCondition.UNKNOWN
    return _WMO_CONDITIONS.get(code, WeatherCondition.UNKNOWN)


@dataclass(frozen=True)
class WeatherDay:
    """One day of weather.

    A `None` quantity means the source did not answer it. `0.0` means the
    source answered "none" — for precipitation those are different facts, and
    collapsing them is the failure this module exists to prevent.
    """

    day: date
    condition: WeatherCondition
    temperature_min_c: float
    temperature_max_c: float
    precipitation_mm: float | None = None
    precipitation_probability_pct: int | None = None
    precipitation_hours: float | None = None
    uv_index_max: float | None = None
    sunrise: datetime | None = None
    sunset: datetime | None = None

    def __post_init__(self) -> None:
        if self.temperature_min_c > self.temperature_max_c:
            raise ValueError(
                f"temperature_min_c {self.temperature_min_c} exceeds "
                f"temperature_max_c {self.temperature_max_c}"
            )
        if self.precipitation_mm is not None and self.precipitation_mm < 0:
            raise ValueError(f"precipitation_mm cannot be negative, got {self.precipitation_mm}")
        if (
            self.precipitation_probability_pct is not None
            and not 0 <= (self.precipitation_probability_pct) <= 100
        ):
            raise ValueError(
                f"precipitation_probability_pct must be within [0, 100], "
                f"got {self.precipitation_probability_pct}"
            )
        if self.precipitation_hours is not None and not 0 <= self.precipitation_hours <= 24:
            raise ValueError(
                f"precipitation_hours must be within [0, 24], got {self.precipitation_hours}"
            )
        if self.sunrise and self.sunset and self.sunrise > self.sunset:
            raise ValueError("sunrise must not follow sunset")

    @property
    def precipitation_forecast_dry(self) -> bool:
        """True only when the source positively said nothing will fall."""
        return self.precipitation_mm == 0.0
