'''A weather provider that already knows the answer.

Not a source of weather — a way to tell a render what to draw. Open-Meteo
answers from 92 days back to 16 days ahead, so in November there is no forecast
that will render a July beach and no archive that will render next January's
snow. The panels are seasonal art, which means the season has to be askable for.

It is also the only way to see two weathers side by side, which is how the pose
variance was checked: the same sky on thirty dates should not draw thirty of the
same cat.
'''

from dataclasses import dataclass
from datetime import UTC, date, datetime

from day_context import Fetched, Location, WeatherCondition, WeatherDay

__all__ = ["FixedWeatherProvider"]


@dataclass(frozen=True)
class _Answer:
    """One sky, answered completely.

    Every field is filled because `WeatherDay` reads `None` as "the source did
    not say", and the pipeline refuses a day whose precipitation it was never
    told about. A stub that leaves a field out is a stub that fails, and fails
    for a reason that looks like the pipeline being fussy.
    """

    high_c: float
    low_c: float
    precipitation_mm: float
    precipitation_probability_pct: int


# Plausible numbers per sky, so `--weather snow` is a whole sentence rather than
# a condition with a July temperature and no snowfall attached.
_ANSWERS: dict[WeatherCondition, _Answer] = {
    WeatherCondition.CLEAR: _Answer(24.0, 12.0, 0.0, 0),
    WeatherCondition.MAINLY_CLEAR: _Answer(21.0, 10.0, 0.0, 5),
    WeatherCondition.PARTLY_CLOUDY: _Answer(19.0, 10.0, 0.0, 15),
    WeatherCondition.OVERCAST: _Answer(14.0, 8.0, 0.0, 25),
    WeatherCondition.FOG: _Answer(11.0, 7.0, 0.0, 20),
    WeatherCondition.DRIZZLE: _Answer(13.0, 8.0, 1.4, 60),
    WeatherCondition.RAIN: _Answer(12.0, 7.0, 8.2, 85),
    WeatherCondition.FREEZING_PRECIPITATION: _Answer(1.0, -3.0, 3.0, 80),
    WeatherCondition.SNOW: _Answer(-1.0, -7.0, 6.0, 85),
    WeatherCondition.THUNDERSTORM: _Answer(26.0, 18.0, 15.0, 90),
    WeatherCondition.UNKNOWN: _Answer(15.0, 8.0, 0.0, 0),
}


class FixedWeatherProvider:
    """Answers every day with one condition, chosen by whoever ran the render."""

    name = "fixed"

    def __init__(
        self,
        condition: WeatherCondition | str,
        *,
        temperature_high_c: float | None = None,
        temperature_low_c: float | None = None,
    ) -> None:
        self._condition = (
            condition if isinstance(condition, WeatherCondition) else WeatherCondition(condition)
        )
        defaults = _ANSWERS[self._condition]
        self._high = defaults.high_c if temperature_high_c is None else temperature_high_c
        self._low = defaults.low_c if temperature_low_c is None else temperature_low_c
        self._defaults = defaults

    def fetch_weather(self, location: Location, day: date) -> Fetched[WeatherDay]:
        return Fetched(
            value=WeatherDay(
                day=day,
                condition=self._condition,
                temperature_min_c=self._low,
                temperature_max_c=self._high,
                precipitation_mm=self._defaults.precipitation_mm,
                precipitation_probability_pct=self._defaults.precipitation_probability_pct,
            ),
            source=self.name,
            # Honest: this value really was produced now, and `fixed` in the
            # provenance says it was never a forecast about anything.
            fetched_at=datetime.now(UTC),
        )
