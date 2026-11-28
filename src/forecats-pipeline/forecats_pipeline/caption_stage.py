'''Stage 2: turn a day into the words the renderer is given.

Deterministic, with no model call. The shape of the prompt is not an accident:
it is jwardbond/forecats' `generate_image()` prompt, ported after a control
render proved it drew better pictures than ours from the same model, the same
seed and the same reference photos.

What upstream knows that our template did not:

*   **Name a background.** Ours described what the cats do and never said where
    they are. The model filled the gap from the only noun offered, so "cool tiles
    in front of an open window" became a bathroom and a snowy day became two cats
    in a white void.
*   **Say the weather must be visible.** Light alone is a mood; snow on a fence
    is a fact.
*   **Do not ask for an edit of the photos.** "Edit <Picture 1>" reads as *change
    this picture*, which anchors the pose, the camera and the room to the input
    photo. The photos are an identity reference and nothing else.

What we keep that upstream does not have: the owner's proven descriptions, the
negative rules that stop two ginger brothers merging, the researched festival
props, and a night variant of every sky.
'''

import hashlib
from datetime import date

from forecats_pipeline.contracts import Caption, DayContext, Household, Scene, WeatherToday, day_seed

__all__ = [
    "PANEL_STYLE",
    "draft_caption",
    "style_for_day",
    "table_scene",
    "template_hash",
]

# The style a household that names none in `household.yaml` is drawn in, and the
# style every panel of the first year was drawn in. Cartoon, per the owner's pick
# of forecats' look, and deliberately free of fine detail: the destination is a
# colour e-ink panel, where thin texture dithers away into mud. Deliberately
# silent about the setting — the first version of this string said "warm detailed
# interior", which put every panel of a year indoors no matter what the day said.
#
# The list a day actually picks from is data, in `household.yaml`.
PANEL_STYLE = (
    "bright flat cartoon illustration, bold clean outlines, saturated cheerful "
    "colours, deep readable depth"
)

_TEMPLATE = """You are an AI artist creating a daily weather illustration of {n_pets} pet cats, from a weather forecast and an activity.

The pets:
{identities}

You are given {n_pets} input images: {photo_names}. Use them only as a reference for each cat's face, coat and markings. The pose, the camera and the setting belong to today, not to the photos.
{consistency}
Today is {date}, at {location}. The forecast: {weather}.
{occasion}The activity they are doing today is:
Activity: {activity}
Foreground: {foreground}
Background: {background}

The art style should be: {style}

Create a vibrant and engaging illustration that captures the essence of the weather and the activity. The weather is important, so include elements that clearly indicate the weather conditions, and make the scene lively and appropriate for the time of year.

In the bottom left corner, drawn in the style of the illustration rather than pasted on top of it, a small weather box reading: {weather_words}, high {high}, low {low}, {date}.

Heuristics:
- Capture the mood of the weather, the season and the activity.
- This is for a colour e-ink screen, so avoid very fine detail that would be lost in dithering.

Rules:
- Only a single image.
- Compose for a square crop; keep nothing important near the edges.
- Keep the weather box clear of the edges and of the cats.
- No text anywhere except in the weather box.
"""

# What the sky does to the light. Phrased as light, not ground: the first panels
# described the pavement for any rainless day and the model obliged with a desert.
#
# Keyed by WeatherCondition's own spelling. These keys were once written with
# spaces while the domain answers with hyphens, and three of eleven skies fell
# through to `unknown` for a year without a single test noticing.
_SKY_LIGHT = {
    "clear": "bright warm sunlight and a clean blue sky",
    "mainly-clear": "soft warm sunlight under a mostly clear sky",
    "partly-cloudy": "dappled sunlight with drifting clouds",
    "overcast": "cool even light under a heavy grey sky",
    "fog": "soft mist with distant shapes going hazy",
    "drizzle": "fine drifting rain and glossy wet surfaces",
    "rain": "steady rain, rippled puddles, an umbrella",
    "freezing-precipitation": "sleet glazing everything",
    "snow": "falling snow blanketing the ground",
    "thunderstorm": "dramatic storm light and a dark electric sky",
    "unknown": "ambiguous light, the sky half seen through cloud",
}

# The same weather after dark. A separate table rather than a suffix, because
# night changes what the light is without changing what falls from the sky.
_NIGHT_SKY_LIGHT = {
    "clear": "cool moonlight and a deep blue sky scattered with stars",
    "mainly-clear": "moonlight thinning through high cloud",
    "partly-cloudy": "moonlight opening and closing behind drifting cloud",
    "overcast": "flat dim light under a low grey night sky",
    "fog": "mist lit from below by lamplight",
    "drizzle": "fine rain glinting in lamplight on wet surfaces",
    "rain": "rain falling through pools of lamplight, rippled puddles",
    "freezing-precipitation": "sleet glazing everything under a streetlight",
    "snow": "snow falling quietly through the glow of a porch light",
    "thunderstorm": "lightning splitting a black sky",
    "unknown": "the sky half seen through night cloud",
}

# Where the day happens, per sky. Written out because the model is otherwise
# obliged to invent a room from the activity, and does so literally.
_BACKGROUNDS: dict[str, dict[str, str]] = {
    "snow": {
        "winter": "a snow-covered front garden with a picket fence, bare birch trees, "
        "a shovelled stone path, and warm light in the windows of the house behind",
        "any": "open ground under a low winter sky, with a fence line and bare trees",
    },
    "clear": {
        "any": "a bright room with a window looking out over rooftops under a clear sky",
        "winter": "a bright cold living room with a fire laid ready, thick rugs, and "
        "snow visible through a big window",
        "spring": "a garden coming back to life: new green, blossom on the branch of a "
        "tree, an open door with the mat still wet",
        "summer": "a sunny back garden with a spinning sprinkler, an inflatable pool, "
        "green lawn, a white fence and a bright blue sky with a few small clouds",
        "autumn": "a garden mid-turn: a pile of raked leaves, conkers on the path, a "
        "ladder against the gutter and a grey-warm sky",
    },
    "mainly-clear": {"any": "a bright room with a window looking out over rooftops and "
        "a sky that has just cleared"},
    "partly-cloudy": {"any": "a garden under moving cloud, patches of sun crossing the "
        "lawn and the hedge bending slightly"},
    "overcast": {"any": "a grey afternoon through the front window, the garden flat and "
        "still, the room warm and lit by contrast"},
    "fog": {"any": "a garden with the far half missing, the fence posts fading out into "
        "white, the near ones sharp and wet"},
    "drizzle": {"any": "a doorstep and a garden going soft and grey under a fine rain, "
        "leaves glossy on the path"},
    "rain": {"any": "a wet pavement of puddles reflecting a row of houses, gutters "
        "running, the sky low and grey"},
    "freezing-precipitation": {"any": "a garden glazed in clear ice, branches varnished, "
        "the air hard and grey"},
    "thunderstorm": {"any": "a room lit by a flash through the window, the garden beyond "
        "it silver and bending"},
    "unknown": {"any": "an ordinary day, the sky not quite committed"},
}

# What the two of them get up to, per sky and season. The date picks one, so a
# month of the same weather does not draw the same picture thirty times.
_PLAYS: dict[str, dict[str, tuple[str, ...]]] = {
    "clear": {
        "winter": (
            "drag every cushion into the rectangle of winter sun and fight over the best one",
            "stalk snow-globes from the top of the sofa",
            "wrestle over a crumpled ball of string on the rug",
            "bat the snow off the window from the warm side, leaving clean paw-shaped holes",
        ),
        "spring": (
            "bounce on the windowsill watching birds go past",
            "wallow in a patch of new grass that has just dried off",
            "ambush the falling petals of a blossom branch",
            "chase a butterfly across the lawn and miss badly",
        ),
        "summer": (
            "share a striped beach towel, sunglasses and sun hats on the lawn",
            "take turns ambushing the sprinkler and getting soaked for it",
            "steal a popsicle off the table and melt it before they are caught",
            "guard a bowl of ice cream that is not theirs",
        ),
        "autumn": (
            "pounce into a pile of raked leaves and scatter them",
            "hunt a drifting leaf across the pavement",
            "hoard conkers under the sofa",
            "drag the good blanket off the chair and pile it by the fire, badly",
        ),
    },
    "mainly-clear": {
        "any": (
            "stack the socks they stole from the laundry basket into a tower they keep knocking over",
            "race a sunbeam up the wall",
            "patrol the top of the bookshelves for a better view",
        )
    },
    "partly-cloudy": {
        "any": (
            "take turns in and out of the moving patches of sun",
            "chase the shadow of a cloud across the lawn",
            "argue over a sunbeam that keeps going away",
        )
    },
    "overcast": {
        "any": (
            "push a toy mouse under the front door, then go and fetch it again",
            "build a fort out of every cushion in the house",
            "have a slow wrestling match on the best chair",
        )
    },
    "fog": {
        "any": (
            "carry every stick in the garden in from the fog, one at a time",
            "patrol the edge of the mist on the porch",
        )
    },
    "drizzle": {
        "any": (
            "sample rain from the doorstep and decisively dislike it",
            "share an umbrella, lose the argument with it, and stay under it anyway",
        )
    },
    "rain": {
        "any": (
            "jump into a puddle on the pavement, badly, on purpose",
            "watch the rain from a window ledge under a blanket",
            "bat raindrops off the outside of the glass",
        )
    },
    "snow": {
        "any": (
            "have a snowball fight behind a small snow-cat they have built",
            "sled down the garden steps on a baking tray",
            "wear tiny mittens and fail to walk in it",
            "catch snowflakes off the windowsill from a warm room",
        )
    },
    "freezing-precipitation": {
        "any": (
            "lick the first icy railing of the year and immediately regret it",
            "huddle under one blanket on the radiator",
        )
    },
    "thunderstorm": {
        "any": (
            "shelter inside a blanket fort from the thunder",
            "watch the lightning from the bottom of the stairs",
        )
    },
    "unknown": {"any": ("do something they are both entirely committed to",)},
}

# The same idea for a day with a calendar entry on it. "In the middle of the
# celebration" is a pose, and it was the same pose every year.
_CELEBRATION_PLAYS = (
    "wear the party hats and refuse to accept it",
    "knock the decorations off the table one at a time",
    "guard the food from the wrong side of the table",
    "unwrap the ribbon off something far too large for them",
    "supervise the preparations from inside the cardboard box",
    "investigate the candles from a sensible distance",
    "fall asleep in the middle of the tidying up",
    "make their own present the main event",
)

# Meteorological seasons by month, for the household's northern-hemisphere
# garden. A household in the south needs this inverted, and the place to do it is
# here rather than spread through the tables above.
_SEASONS = {
    12: "winter", 1: "winter", 2: "winter",
    3: "spring", 4: "spring", 5: "spring",
    6: "summer", 7: "summer", 8: "summer",
    9: "autumn", 10: "autumn", 11: "autumn",
}

# A rule that says "always depict Milo as orange-and-white" restates Milo's
# description one clause later and buys nothing but length. The negatives are the
# ones with nothing else to carry them: they name the mistake a model makes when
# two ginger brothers are close enough to merge.
_NEGATIVE_STARTS = ("never", "do not", "avoid", "not ", "no ")


def template_hash() -> str:
    """Which template built this panel, as something a provenance file can hold.

    The material is the template and the fallback style, both of them fixed for a
    version of this file. The style a given day drew in is recorded beside the
    hash, and rotating it must not move the hash: a year of panels has to stay
    groupable by the words they were all built from.
    """
    material = f"{_TEMPLATE}\n{PANEL_STYLE}".encode()
    return hashlib.sha256(material).hexdigest()[:12]


def style_for_day(household: Household, for_day: date) -> str:
    """The art style this date is drawn in, taken from the household's list.

    Rotated by the day rather than drawn at random: `day_seed` is the rule the
    diffusion seed already follows, so re-rendering a date reproduces the style
    its own provenance names, and a sidecar never describes a drawing that no
    longer exists. Upstream picks at random and keeps nothing; a panel here is
    published with the record of how it was made.

    A household that names no style gets `PANEL_STYLE`, which is what every panel
    was before the list existed.
    """
    styles = household.art_styles or (PANEL_STYLE,)
    return styles[day_seed(for_day) % len(styles)]


def draft_caption(
    context: DayContext,
    household: Household,
    scene: Scene,
    *,
    location: str = "home",
) -> Caption:
    """Write the caption for one day, given the scene someone chose for it.

    Raises:
        ValueError: if the day has no weather. A `DayContext` may legitimately
            carry a refusal instead of a sky, and this stage must not answer that
            day with an invented one.
    """
    if context.weather is None:
        raise ValueError(
            "a caption needs a sky; a day carrying only refusals is declined by the "
            "pipeline before it reaches this stage"
        )
    weather = context.weather
    style = style_for_day(household, context.for_day)
    text = _TEMPLATE.format(
        n_pets=len(household.pets),
        identities=_identities(household),
        photo_names=_photo_names(household),
        consistency=_consistency(household),
        date=context.for_day.strftime("%-d %B %Y"),
        location=location,
        weather=_forecast(weather),
        weather_words=weather.forecast_words,
        high=f"{weather.temperature_high_c:g}",
        low=f"{weather.temperature_low_c:g}",
        occasion=_occasion(context.occasions),
        activity=scene.activity,
        foreground=scene.foreground,
        background=scene.background,
        style=style,
    )
    return Caption(text=text, template_hash=template_hash(), style=style)


def table_scene(context: DayContext, household: Household) -> Scene:
    """The deterministic scene: a play chosen from the sky, the season and the date.

    This is the fallback when no model was asked, and it is deliberately modest.
    A table can hold a few dozen ideas; the point of `ActivityGenerator` is that
    it does not have to hold them all.
    """
    season = _SEASONS[context.for_day.month]
    summary = context.weather.summary if context.weather else "unknown"
    props = _props(context.occasions)
    play = _pick(_CELEBRATION_PLAYS if props else _plays_for(summary, season), context.for_day)
    habit = _habit(household, context.for_day)

    if props:
        return Scene(
            activity=f"celebrating {_named(context.occasions)}",
            foreground=f"The two of them {play}, dressed for the occasion. {habit}".strip(),
            # No props here: the template states what the day looks like, and
            # naming them twice reads as a drafter who was unsure.
            background=_background_for(summary, season),
        )
    return Scene(
        activity=play,
        foreground=f"The two of them {play}. {habit}".strip(),
        background=_background_for(summary, season),
    )


def _background_for(summary: str, season: str) -> str:
    """Where the day happens. Every sky has an `any`, so a season can never miss.

    Written as a lookup rather than `by_season.get(season, by_season["any"])`,
    which evaluates the default eagerly and raises on any sky that omits it.
    """
    by_season = _BACKGROUNDS.get(summary.casefold(), _BACKGROUNDS["unknown"])
    return by_season.get(season) or by_season["any"]


def _identities(household: Household) -> str:
    """Each name, its kind, and the appearance the owner proved against a render."""
    return "\n".join(
        f"- {pet.name}, {pet.kind}: {pet.visual_description.strip()}" for pet in household.pets
    )


def _photo_names(household: Household) -> str:
    """The reference files, named, so a photo can be bound to a name."""
    return ", ".join(
        f"{pet.reference_photo.name} is {pet.name}" for pet in household.pets
    )


def _consistency(household: Household) -> str:
    """The negative space: what the model must not do to these two animals."""
    negatives = [
        rule.strip()
        for rule in household.consistency_rules
        if rule.strip().casefold().startswith(_NEGATIVE_STARTS)
    ]
    if not negatives:
        return ""
    return "Rules about who is who:\n" + "\n".join(f"- {rule}" for rule in negatives) + "\n"


def _forecast(weather: WeatherToday) -> str:
    table = _SKY_LIGHT if weather.is_daylight_at_panel_time else _NIGHT_SKY_LIGHT
    light = table.get(weather.summary.casefold(), table["unknown"])
    return f"{weather.summary.replace('-', ' ')}, {light}"


def _occasion(occasions) -> str:
    """Name the day and say what it looks like there.

    The props are a fact about the day, researched and cached, not a composition
    choice — which is why they live here and not inside the Scene. A generated
    Scene is invented from the date and the sky and never sees them, so putting
    them in the background meant a generated Diwali panel had no Diwali in it.
    """
    if not occasions:
        return ""
    named = _named(occasions)
    props = _dedupe(_props(occasions))
    if not props:
        # Naming the day is honest; inventing what it looks like is not, and an
        # abstraction with no noun behind it renders as cats in an empty field.
        return f"It is also {named}.\n"
    return f"It is also {named}, and the household is full of it: {props}.\n"


def _named(occasions) -> str:
    return ", ".join(occasion.title for occasion in occasions[:2])


def _props(occasions) -> str:
    return ", ".join(
        occasion.described_as for occasion in occasions[:2] if occasion.described_as
    )


def _dedupe(props: str) -> str:
    """Drop repeated props. Two festivals on one day are the same evening, and a
    noun listed twice only tells the model the drafter was unsure."""
    seen: dict[str, None] = {}
    for phrase in props.split(","):
        phrase = phrase.strip()
        if phrase:
            seen.setdefault(phrase.lower(), phrase)
    return ", ".join(seen.values())


def _plays_for(summary: str, season: str) -> tuple[str, ...]:
    by_season = _PLAYS.get(summary.casefold(), _PLAYS["unknown"])
    return by_season.get(season) or by_season["any"]


def _pick(options, for_day: date):
    return options[for_day.toordinal() % len(options)]


def _habit(household: Household, for_day: date) -> str:
    """One pet's signature habit, on some days, as flavour rather than composition.

    Every day is wrong in its own way: a signature detail in every panel is a
    costume, and Milo would carry that ball into a snowstorm.
    """
    pets = [pet for pet in household.pets if pet.signature_details]
    if not pets or for_day.toordinal() % 3:
        return ""
    pet = pets[for_day.toordinal() % len(pets)]
    detail = pet.signature_details[for_day.toordinal() % len(pet.signature_details)]
    return f"{pet.name}, as ever, {detail.strip().rstrip('.').lower()}."
