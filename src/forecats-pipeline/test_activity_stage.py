"""A model invents the day's pose; a table cannot, and the owner saw the difference."""

import json
from datetime import UTC, date, datetime

from forecats_pipeline.activity_stage import ACTIVITY_INSTRUCTIONS, ActivityGenerator
from forecats_pipeline.contracts import DayContext, Occasion, WeatherToday
from conftest import two_pets

ANSWER = (
    "Activity: Building a snow cat, Foreground: Milo and Mochi wearing red knit scarves "
    "and tiny mittens, packing snow into a small cat-shaped snowman, Background: a "
    "snow-covered front garden with a picket fence and bare birch trees"
)


class Gateway:
    def __init__(self, content: str = ANSWER) -> None:
        self._content = content
        self.bodies: list[dict] = []
        self.calls = 0

    def __call__(self, request, timeout=None):
        self.calls += 1
        self.bodies.append(json.loads(request.data))
        payload = {"choices": [{"message": {"content": self._content}}]}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

            def read(self):
                return json.dumps(payload).encode()

        return Response()


def day(summary="snow", on=date(2026, 1, 14), occasions=()) -> DayContext:
    return DayContext(
        for_day=on,
        timezone="America/New_York",
        weather=WeatherToday(
            summary=summary,
            temperature_high_c=-1.0,
            temperature_low_c=-7.0,
            precipitation_mm=6.0,
            precipitation_probability_pct=85,
            is_daylight_at_panel_time=True,
            source="fixed",
            fetched_at=datetime(2026, 1, 1, tzinfo=UTC),
        ),
        occasions=occasions,
    )


def generator(tmp_path, gateway, monkeypatch) -> ActivityGenerator:
    monkeypatch.setattr("urllib.request.urlopen", gateway)
    return ActivityGenerator(
        endpoint="http://model.test/v1/chat/completions",
        history_path=tmp_path / "activity-history.json",
        cache_path=tmp_path / "activity-cache.json",
    )


def test_the_three_part_answer_becomes_a_scene(tmp_path, monkeypatch):
    scene = generator(tmp_path, Gateway(), monkeypatch).scene_for(day(), two_pets())

    assert scene.activity == "Building a snow cat"
    assert "red knit scarves" in scene.foreground
    assert "picket fence" in scene.background


def test_an_answer_missing_its_foreground_is_no_answer(tmp_path, monkeypatch):
    """A brief with no foreground is cats standing in a named room.

    That is the exact failure this stage was written to end, so a partial reply
    has to fall back to the table rather than render.
    """
    partial = Gateway("Activity: Napping, Background: a sunny windowsill")

    assert generator(tmp_path, partial, monkeypatch).scene_for(day(), two_pets()) is None


def test_a_model_that_cannot_be_reached_yields_no_scene(tmp_path, monkeypatch):
    def down(request, timeout=None):
        raise OSError("connection refused")

    monkeypatch.setattr("urllib.request.urlopen", down)
    researcher = ActivityGenerator(endpoint="http://model.test/v1/chat/completions")

    assert researcher.scene_for(day(), two_pets()) is None


def test_yesterday_is_shown_so_today_is_not_the_same(tmp_path, monkeypatch):
    """The history is the whole mechanism; without it the model repeats itself."""
    gateway = Gateway()
    first = generator(tmp_path, gateway, monkeypatch).scene_for(day(), two_pets())
    assert first is not None

    again = generator(tmp_path, gateway, monkeypatch).scene_for(
        day(on=date(2026, 1, 15)), two_pets()
    )

    assert again is not None
    already = gateway.bodies[-1]["messages"][-1]["content"]
    assert "Building a snow cat" in already, "the last twenty have to travel with the ask"


def test_a_generated_scene_is_reused_when_a_date_is_re_rendered(tmp_path, monkeypatch):
    """The seed is the date, so the picture a date draws must not change under it."""
    gateway = Gateway()
    generator(tmp_path, gateway, monkeypatch).scene_for(day(), two_pets())
    assert gateway.calls == 1

    second = generator(tmp_path, gateway, monkeypatch).scene_for(day(), two_pets())

    assert gateway.calls == 1, "a re-render must not invent a different day"
    assert second is not None and second.activity == "Building a snow cat"


def test_the_brief_asks_for_hands_and_forbids_sitting():
    """The owner's comparison: the control wore hats and rolled snowballs, ours sat.

    A heuristic that is not in the instructions is a preference nobody has.
    """
    assert "clothing or accessories" in ACTIVITY_INSTRUCTIONS
    assert "must not be similar to any you gave in the last twenty days" in ACTIVITY_INSTRUCTIONS
    # Preferred, not required: the owner wants quiet days to stay possible.
    assert "A quiet day is allowed" in ACTIVITY_INSTRUCTIONS


def test_habits_are_offered_as_seasoning_not_as_the_composition(tmp_path, monkeypatch):
    """Milo's ball should still be there at a snowball fight, not become one.

    These details used to be the whole pose, which is how one cat ended up on his
    back and the other beside a ball in every panel for a year.
    """
    gateway = Gateway()

    generator(tmp_path, gateway, monkeypatch).scene_for(day(), two_pets())

    brief = gateway.bodies[-1]["messages"][-1]["content"]
    assert "Their habits:" in brief
    assert "sparkling ball toy" in brief
    assert "at most one of their habits" in gateway.bodies[-1]["messages"][0]["content"]


def test_the_day_and_the_forecast_reach_the_model(tmp_path, monkeypatch):
    gateway = Gateway()
    diwali = Occasion("Diwali/Deepavali", all_day=True, described_as="oil lamps")

    generator(tmp_path, gateway, monkeypatch).scene_for(day("clear", occasions=(diwali,)), two_pets())

    brief = gateway.bodies[0]["messages"][-1]["content"]
    assert "Milo" in brief and "Mochi" in brief
    assert "clear" in brief
    assert "Diwali/Deepavali" in brief
