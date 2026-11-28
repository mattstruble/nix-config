"""The caption stub has to be boring, explainable, and honest about the sky."""

import re
from dataclasses import replace
from pathlib import Path
from datetime import UTC, date, datetime

import pytest
from forecats_pipeline import caption_stage
from forecats_pipeline.caption_stage import (
    _NIGHT_SKY_LIGHT,
    _PLAYS,
    _BACKGROUNDS,
    _SKY_LIGHT,
    PANEL_STYLE,
    draft_caption as _draft_caption,
    table_scene,
    template_hash,
)
from conftest import two_pets
from forecats_pipeline.contracts import DayContext, Occasion, WeatherToday, day_seed
from forecats_pipeline.household import load_household
from day_context.weather import WeatherCondition

MORNING = datetime(2026, 3, 8, 7, 30, tzinfo=UTC)

# The household file the nightly is drawn from: the list of art styles is data
# there, so every assertion about that list reads this file rather than writing
# the list out a second time.
HOUSEHOLD_FILE = Path(__file__).parent / "household.yaml"


def draft_caption(context, household):
    """A caption, with the deterministic scene the pipeline falls back to."""
    return _draft_caption(context, household, table_scene(context, household))


def weather(**over) -> WeatherToday:
    base = dict(
        summary="rain",
        temperature_high_c=7.5,
        temperature_low_c=1.5,
        precipitation_mm=12.0,
        precipitation_probability_pct=90,
        is_daylight_at_panel_time=True,
        source="open-meteo",
        fetched_at=MORNING,
    )
    return WeatherToday(**{**base, **over})


def context(**over) -> DayContext:
    base = dict(
        for_day=date(2026, 3, 8),
        timezone="America/New_York",
        weather=weather(),
        occasions=(),
    )
    return DayContext(**{**base, **over})


def test_the_weather_wins_the_scene_and_the_occasion_wins_the_decoration():
    caption = draft_caption(context(occasions=(Occasion("Birthday dinner", all_day=False),)), two_pets())

    assert "steady rain" in caption.text
    assert "puddles" in caption.text
    assert "Birthday dinner" in caption.text
    # "clearly recognisable" is in the composition rule, so ban the phrase a
    # borrowed sunny mood would actually introduce.
    assert "clear sky" not in caption.text and "sunny" not in caption.text


def test_an_empty_calendar_invents_no_celebration():
    """Silence about the calendar beats a mood the day did not earn."""
    text = draft_caption(context(), two_pets()).text

    assert "celebrating" not in text
    assert "Milo" in text and "Mochi" in text


def test_the_decoration_is_bounded_so_a_crowded_calendar_does_not_become_the_subject():
    occasions = tuple(Occasion(f"Event {index}", all_day=False) for index in range(6))

    text = draft_caption(context(occasions=occasions), two_pets()).text

    assert "Event 0" in text and "Event 1" in text
    assert "Event 2" not in text


def test_the_hash_names_the_words_and_not_the_day():
    rainy = draft_caption(context(), two_pets())
    snowy = draft_caption(context(weather=weather(summary="snow", precipitation_mm=0.0)), two_pets())

    assert rainy.template_hash == snowy.template_hash == template_hash()


def test_a_different_style_is_a_different_template_hash(monkeypatch):
    before = template_hash()

    monkeypatch.setattr(caption_stage, "PANEL_STYLE", "engraving, ink, single colour")

    assert template_hash() != before


def test_the_stub_never_invents_a_sky_for_a_day_that_had_none():
    blind = context(weather=None, occasions=(), weather_refusals=("open-meteo: unreachable: down",))

    with pytest.raises(ValueError, match="needs a sky"):
        draft_caption(blind, two_pets())


def test_each_pet_is_bound_to_its_photo_without_borrowing_the_photos_room():
    """The photos say who is who. They used to also say how the cats sat.

    "Edit <Picture 1> and <Picture 2>" reads as *change this picture*, and the
    renders obliged with the composition, the pose and the room of the input
    photo. Upstream's wording — reference for appearance, nothing else — drew
    better from the same model and the same seed.
    """
    text = draft_caption(context(), two_pets()).text

    assert "milo.jpg is Milo" in text
    assert "mochi.jpg is Mochi" in text
    assert "only as a reference for each cat's face, coat and markings" in text
    assert "belong to today, not to the photos" in text
    assert not text.startswith("Edit ")


def test_a_household_with_no_pets_cannot_be_captioned():
    """The photorealistic empty building: no subjects, so the model drew a street."""
    from forecats_pipeline.contracts import Household

    with pytest.raises(ValueError, match="no pets"):
        Household(pets=())


def test_a_pet_with_no_appearance_is_refused_at_construction():
    from forecats_pipeline.contracts import Pet

    with pytest.raises(ValueError, match="no visual description"):
        Pet("Nobody", "cat", "", Path("/refs/x.jpg"))


def test_the_weather_gauge_is_asked_for_in_the_style_of_the_drawing():
    """A pasted-on plate reads as a sticker; the gauge has to belong to the art."""
    text = draft_caption(context(), two_pets()).text

    assert "bottom left corner" in text
    assert "drawn in the style of the illustration rather than pasted on top" in text
    assert "Hi 7.5" not in text  # the numbers are given bare, for the model to draw


def test_no_day_prompts_for_bare_ground():
    """The first panels were cats in a desert: the dry-day line described dust."""
    for summary in ("clear", "overcast", "mainly-clear", "partly-cloudy"):
        assert "dust" not in draft_caption(context(weather=weather(summary=summary)), two_pets()).text


def test_an_unresearched_occasion_names_the_day_without_inventing_its_look():
    """No research, no props. "Surrounded by what it looks like" renders as an
    empty field, because it offers the image model no noun to hold."""
    text = draft_caption(context(occasions=(Occasion("Diwali/Deepavali", all_day=True),)), two_pets()).text

    assert "Diwali/Deepavali" in text
    assert "what it looks like" not in text


def test_a_researched_occasion_puts_the_things_themselves_in_the_prompt():
    occasion = Occasion(
        "Diwali/Deepavali",
        all_day=True,
        described_as="oil lamps set in windows, marigold garlands, a coloured rangoli",
    )

    text = draft_caption(context(occasions=(occasion,)), two_pets()).text

    assert "oil lamps set in windows" in text
    assert "marigold garlands" in text
    assert "coloured rangoli" in text


def test_a_clear_evening_is_not_asked_for_a_blue_sky():
    """Halloween is an evening; 'bright warm sunlight' contradicts the date."""
    evening = draft_caption(
        context(weather=weather(summary="clear", is_daylight_at_panel_time=False)), two_pets()
    ).text

    assert "sunlight" not in evening
    assert "moonlight" in evening
    assert "clear" in evening, "night changes the light, not the weather"


def test_every_day_sky_has_a_night_counterpart():
    """A summary missing from the night table would silently render as daytime."""
    assert _SKY_LIGHT.keys() == _NIGHT_SKY_LIGHT.keys()


def test_two_festivals_one_day_do_not_list_the_same_lamp_twice():
    """Same evening, same room: a repeated prop reads as uncertainty to the model."""
    diwali = Occasion("Diwali/Deepavali", all_day=True, described_as="marigold garlands, oil lamps")
    naraka = Occasion("Naraka Chaturdasi", all_day=True, described_as="oil lamps, brass plates of sweets")

    text = draft_caption(context(occasions=(diwali, naraka)), two_pets()).text

    assert text.count("oil lamps") == 1
    assert "brass plates of sweets" in text


def test_a_prop_is_not_a_costume():
    """Milo's ball rotates rather than following him into every scene."""
    days = [date(2026, 11, day) for day in range(1, 15)]
    prompts = [
        draft_caption(
            DayContext(for_day=day, timezone="America/New_York", weather=weather(), occasions=()),
            two_pets(),
        ).text
        for day in days
    ]
    with_ball = [text for text in prompts if "sparkling ball" in text]

    assert 0 < len(with_ball) < len(prompts), "sometimes the ball, sometimes not"


def test_the_same_date_always_asks_for_the_same_prop():
    """Rotation is by date, so a re-render reproduces the picture the seed implies."""
    monday = date(2026, 11, 9)
    day = DayContext(for_day=monday, timezone="America/New_York", weather=weather(), occasions=())

    first = draft_caption(day, two_pets()).text
    again = draft_caption(day, two_pets()).text

    assert first == again


def scene(day, summary="clear", occasions=()):
    context = DayContext(
        for_day=day,
        timezone="America/New_York",
        weather=weather(summary=summary),
        occasions=occasions,
    )
    return draft_caption(context, two_pets()).text


def test_the_same_weather_across_a_month_does_not_render_the_same_picture():
    """The complaint this exists to answer: Milo always standing, Mochi always flat."""
    days = [date(2026, 1, day) for day in range(1, 29)]
    plays = {scene(day, "snow").split("two of them ")[1].split(".")[0] for day in days}

    assert len(plays) >= 4, f"a month of snow gave only {len(plays)} compositions"


def test_the_weather_is_what_they_do_not_just_what_is_behind_them():
    """A blizzard used to render as two cats sitting in a room while snow happened."""
    text = scene(date(2026, 1, 14), "snow")

    assert "snow" in text or "mittens" in text or "sled" in text
    assert "Background:" in text, "a named place is what stopped snow becoming a void"


def test_a_clear_december_cannot_draw_a_summer_day():
    """The same sky in January and July must not reach for the same plays.

    The play sets come out of the table rather than being listed again here: a
    second hand-written list could agree with the code and still be wrong.
    """
    summer = _PLAYS["clear"]["summer"]
    winter = _PLAYS["clear"]["winter"]

    january = [scene(date(2026, 1, day), "clear") for day in range(1, 32)]
    july = [scene(date(2026, 7, day), "clear") for day in range(1, 32)]

    assert not [text for text in january if any(play in text for play in summer)]
    assert not [text for text in july if any(play in text for play in winter)]
    assert any(any(play in text for play in summer) for text in july)


def test_the_style_string_does_not_chose_the_room():
    """'warm detailed interior' in the style put every panel indoors for a year.

    The list is data in the household file, so the words it may not contain are
    checked against that file: a hand-copied list here would pass while the real
    one grew a room.
    """
    shipped = load_household(HOUSEHOLD_FILE).art_styles

    for style in (PANEL_STYLE, *shipped):
        for place in ("interior", "indoor", "outdoor", "room"):
            assert place not in style.lower(), f"{style!r} names where the cats are"


def test_a_day_is_drawn_in_one_of_the_household_styles():
    """One style for a year of panels is the same picture, thirty times a month."""
    caption = draft_caption(context(), two_pets())

    assert caption.style in two_pets().art_styles
    assert f"The art style should be: {caption.style}" in caption.text


def test_the_style_and_the_seed_come_from_one_number():
    """A date re-rendered reproduces its style, by the rule its seed follows.

    The renderer's seed is `day_seed(day)` and the style is that number's place in
    the household's list. A style drawn from the clock instead would leave the
    provenance beside a panel describing a drawing that no longer exists.
    """
    styles = two_pets().art_styles

    for day in (date(2026, 3, 8), date(2026, 11, 27), date(2027, 1, 1)):
        caption = draft_caption(context(for_day=day), two_pets())
        assert caption.style == styles[day_seed(day) % len(styles)]


def test_a_month_of_days_is_drawn_in_every_style_the_household_names():
    """The rotation runs: consecutive days walk the list, so none of it goes unused."""
    drawn = {
        draft_caption(context(for_day=date(2026, 5, day)), two_pets()).style
        for day in range(1, 32)
    }

    assert drawn == set(two_pets().art_styles)


def test_a_household_naming_no_style_is_drawn_in_the_one_this_stage_ships_with():
    """A household file older than the list still renders, in the style it knew."""
    caption = draft_caption(context(), replace(two_pets(), art_styles=()))

    assert caption.style == PANEL_STYLE


def test_a_celebration_asks_for_an_action_not_a_pose():
    """'in the middle of the celebration' is a pose, and the same one every year."""
    diwali = Occasion("Diwali/Deepavali", all_day=True, described_as="oil lamps, rangoli")
    days = [date(2026, 11, day) for day in range(1, 25)]
    plays = {
        scene(day, "clear", (diwali,)).split("The two of them ")[1].split(", dressed")[0]
        for day in days
    }

    assert len(plays) >= 4
    assert all(not play.startswith(("are ", "is ")) for play in plays), "reads after a subject"


def test_every_condition_the_domain_can_answer_has_words():
    """A table key that no real summary can spell renders as `unknown`, silently.

    `mainly clear`, `partly cloudy` and `freezing precipitation` were written with
    spaces while `WeatherCondition` answers with hyphens, so three of eleven skies
    fell through to the fallback and nobody noticed in a year of panels. The
    condition set is the domain's own; the tables have to cover it.
    """
    spellings = {condition.value for condition in WeatherCondition}

    assert spellings <= set(_SKY_LIGHT), spellings - set(_SKY_LIGHT)
    assert spellings <= set(_NIGHT_SKY_LIGHT), spellings - set(_NIGHT_SKY_LIGHT)
    assert spellings <= set(_PLAYS), spellings - set(_PLAYS)
    assert spellings <= set(_BACKGROUNDS), spellings - set(_BACKGROUNDS)


def test_every_play_table_covers_every_season_it_claims():
    for condition, by_season in _PLAYS.items():
        assert "any" in by_season or set(by_season) >= {"winter", "spring", "summer", "autumn"}, (
            f"{condition} offers plays for some seasons and not the others"
        )


PASSIVE_PLAY = re.compile(
    r"^(sit|stare|watch|lie|lay|press|bathe|rest|sleep|gaze|look)\b|\bwatch the\b|\bsit at\b"
)


def test_most_fallback_plays_have_something_in_their_paws():
    """The owner's comparison named the failure: the control rolled snowballs, ours sat.

    Not a ban. "Watch the rain from a window ledge under a blanket" is a good
    panel, and a card where something is happening every single day is a card
    that has stopped letting the weather be the point. Activity is preferred;
    a quiet day is allowed to be quiet.
    """
    plays = [play for by_season in _PLAYS.values() for group in by_season.values() for play in group]
    passive = [play for play in plays if PASSIVE_PLAY.search(play)]

    assert len(passive) * 3 <= len(plays), f"{len(passive)} of {len(plays)} plays are sitting"


def test_researched_props_survive_a_generated_scene():
    """A generated Scene is invented from the date and the sky, and never sees the
    research. Carrying the props inside the Scene meant a generated Diwali panel
    had no Diwali in it — the failure the research stage exists to prevent.

    So the props are a fact about the day, stated by the template, whatever
    supplied the composition.
    """
    from forecats_pipeline.contracts import Scene

    diwali = Occasion("Diwali/Deepavali", all_day=True, described_as="oil lamps, a coloured rangoli")
    day = context(occasions=(diwali,))
    invented = Scene(
        activity="Lighting the lamps",
        foreground="The two of them wearing small silk scarves",
        background="a living room with low furniture",
    )

    text = _draft_caption(day, two_pets(), invented).text

    assert "Diwali/Deepavali" in text
    assert "oil lamps" in text
    assert "coloured rangoli" in text


def test_researched_props_are_named_once_whatever_the_scene():
    diwali = Occasion("Diwali/Deepavali", all_day=True, described_as="oil lamps, marigold garlands")
    naraka = Occasion("Naraka Chaturdasi", all_day=True, described_as="oil lamps, brass plates")
    day = context(occasions=(diwali, naraka))

    text = draft_caption(day, two_pets()).text

    assert text.count("oil lamps") == 1
