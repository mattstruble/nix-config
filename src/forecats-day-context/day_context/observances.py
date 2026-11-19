"""Named days that a place marks, and the day they fall on."""

from dataclasses import dataclass
from datetime import date
from enum import StrEnum

__all__ = ["HolidayDay", "Observance", "ObservanceKind"]


class ObservanceKind(StrEnum):
    """Whether the day is off, or merely remembered."""

    PUBLIC_HOLIDAY = "public-holiday"
    OBSERVANCE = "observance"


@dataclass(frozen=True)
class Observance:
    name: str
    day: date
    kind: ObservanceKind

    def __post_init__(self) -> None:
        if not self.name.strip():
            raise ValueError("an observance must be named")


@dataclass(frozen=True)
class HolidayDay:
    """The observances that fall on one day.

    `region` records which rule set was applied, so a caller that asked for one
    place and received another's calendar can see that it did.
    """

    day: date
    region: str
    observances: tuple[Observance, ...] = ()

    def __post_init__(self) -> None:
        if not self.region.strip():
            raise ValueError("region must name the rule set that was applied")
        if not isinstance(self.observances, tuple):
            raise ValueError("observances must be a tuple so a held day cannot be mutated")

    def __len__(self) -> int:
        return len(self.observances)

    @property
    def is_holiday(self) -> bool:
        return any(item.kind is ObservanceKind.PUBLIC_HOLIDAY for item in self.observances)
