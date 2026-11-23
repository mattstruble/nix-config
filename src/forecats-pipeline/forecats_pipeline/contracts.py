'''Typed values crossing stage boundaries.

Every stage returns either a value or a PipelineRefusal. A refusal is data, not
an exception, because "the weather service was down" and "today has nothing in
it" must not look the same to the thing that decides whether to publish.
'''

from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

__all__ = [
    "Caption",
    "DayContext",
    "Occasion",
    "Pet",
    "PipelineRefusal",
    "Published",
    "Staleness",
    "WeatherToday",
    "Household",
]


@dataclass(frozen=True)
class WeatherToday:
    """What the sky is doing, as the renderer needs it and no more.

    Deliberately not the provider's own value type: stages exchange plain data
    so a boundary can become an n8n node without either side importing the
    other. The provider's richer forecast stays where it is.
    """

    summary: str
    temperature_high_c: float
    temperature_low_c: float
    precipitation_mm: float
    precipitation_probability_pct: int
    is_daylight_at_panel_time: bool
    source: str
    fetched_at: datetime

    def __post_init__(self) -> None:
        if self.fetched_at.tzinfo is None:
            raise ValueError("fetched_at must be timezone-aware; it is the freshness proof")
        if not 0 <= self.precipitation_probability_pct <= 100:
            raise ValueError(
                f"precipitation_probability_pct must be within [0, 100], "
                f"got {self.precipitation_probability_pct}"
            )
        if self.temperature_low_c > self.temperature_high_c:
            raise ValueError(
                f"the low ({self.temperature_low_c}) cannot exceed the high "
                f"({self.temperature_high_c}); a panel that prints them the wrong "
                "way round states a weather the sky did not forecast"
            )

    @property
    def is_dry(self) -> bool:
        """True only when the source positively said nothing will fall."""
        return self.precipitation_mm == 0.0

    @property
    def forecast_words(self) -> str:
        """The three-word weather line the panel's corner box carries.

        Built here rather than by the overlay so the words and the numbers they
        describe come from one place and cannot disagree.
        """
        return _WEATHER_WORDS.get(self.summary.casefold(), self.summary.replace("-", " ").title())


_WEATHER_WORDS = {
    "clear": "Clear and bright",
    "mainly clear": "Mostly clear",
    "partly cloudy": "Partly cloudy",
    "overcast": "Grey and overcast",
    "fog": "Fog, low visibility",
    "drizzle": "Light drizzle",
    "rain": "Rain, wet ground",
    "freezing precipitation": "Freezing rain",
    "snow": "Snow falling",
    "thunderstorm": "Thunder and lightning",
    "unknown": "Sky unknown",
}


@dataclass(frozen=True)
class Occasion:
    """A calendar event, before and after the model looked at it.

    researched is None when the research stage has not run. It is not False, so
    "we did not ask" cannot be read as "we asked and it means nothing".
    """

    title: str
    all_day: bool
    described_as: str | None = None


@dataclass(frozen=True)
class Pet:
    """One subject the panel is about, and the picture that shows what it looks like.

    The reference photo is identity, not attachment: the prompt binds this name
    to that file's `<Picture N>` index, so a pet listed without its photo is a
    pet the renderer has never met and will invent instead.

    `visual_description` is where inventing stops. The first descriptions in
    this repo were guesses, and one of them called a ginger tabby a black-and-
    white tuxedo — the render then obeyed the words over the photo and produced
    an animal that was almost right, which is worse than obviously wrong.
    """

    name: str
    kind: str
    visual_description: str
    reference_photo: Path
    personality: str = ""
    signature_details: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.name.strip():
            raise ValueError("a pet the prompt cannot name is a pet that will not appear")
        if not self.visual_description.strip():
            raise ValueError(
                f"{self.name}: a pet with no visual description is a pet the model "
                "will colour in from its own imagination"
            )
        if not self.reference_photo.parts:
            raise ValueError(f"{self.name}: a pet needs a reference photo the render can open")


@dataclass(frozen=True)
class Household:
    """Who lives here, and the rules that keep them themselves across pictures.

    `consistency_rules` are negative and deliberate: the pair are similar
    enough that a model will happily swap their markings, and the only thing
    that stopped Mochi acquiring Milo's white chest was being told not to.
    """

    pets: tuple[Pet, ...]
    relationship: tuple[str, ...] = ()
    consistency_rules: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.pets:
            raise ValueError("a household with no pets renders an empty street")
        names = [pet.name for pet in self.pets]
        if len(set(names)) != len(names):
            raise ValueError("two pets with one name cannot be told apart by a prompt")


@dataclass(frozen=True)
class DayContext:
    """Everything the caption stage reads, gathered from the day-context layer."""

    for_day: date
    timezone: str
    weather: WeatherToday | None
    occasions: tuple[Occasion, ...] = ()
    weather_refusals: tuple[str, ...] = field(default_factory=tuple)
    calendar_refusals: tuple[str, ...] = field(default_factory=tuple)

    def __post_init__(self) -> None:
        if self.weather is None and not self.weather_refusals:
            raise ValueError(
                "a day with no weather must carry the refusal that explains it; "
                "an empty weather field is how a stale sky gets rendered silently"
            )
        if self.occasions and self.calendar_refusals:
            raise ValueError(
                "a day whose calendar could not be read has no occasions to show; "
                "rendering a schedule nobody fetched is the same lie as a blank sky"
            )


@dataclass(frozen=True)
class PipelineRefusal:
    """A stage declined to produce a value, and says why."""

    stage: str
    reason: str

    def __post_init__(self) -> None:
        if not self.reason.strip():
            raise ValueError("a refusal must name its cause; a blank reason is unusable")


@dataclass(frozen=True)
class Scene:
    """What the pets are doing, what they wear doing it, and where they are.

    Three fields because that is the shape upstream's activity generator is
    required to answer, and the third is the one our own prompts never supplied.
    With no background named, "cool tiles in front of an open window" rendered as
    a bathroom and a snowy day rendered as two cats standing in a white void —
    the model was not guessing badly, it was completing a prompt that had left
    the room out.
    """

    activity: str
    foreground: str
    background: str


@dataclass(frozen=True)
class Caption:
    """The text handed to the renderer, plus the template that produced it.

    template_hash is what makes a published panel explainable after the fact:
    when a picture is wrong, the hash says which prompt built it.
    """

    text: str
    template_hash: str
    style: str


@dataclass(frozen=True)
class Staleness:
    """How old the newest render is, as a value a viewer can read.

    With no history kept, a stale panel is indistinguishable from a working one
    unless the age is published beside it. This is the only mechanism a viewer
    has to notice the nightly job stopped.
    """

    rendered_at: datetime
    age_hours: float

    def __post_init__(self) -> None:
        if self.rendered_at.tzinfo is None:
            raise ValueError("rendered_at must be timezone-aware to be comparable")
        if self.age_hours < 0:
            raise ValueError(f"age_hours cannot be negative, got {self.age_hours}")


@dataclass(frozen=True)
class Published:
    panel_path: str
    provenance_path: str
    for_day: date
    staleness: Staleness
