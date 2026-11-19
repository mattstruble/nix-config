"""The corner box states the weather, so it must state the forecast's numbers."""

import struct
from datetime import UTC, date, datetime

from forecats_pipeline.contracts import Occasion, WeatherToday
from forecats_pipeline.overlay_stage import forecast_box, overlay_forecast

MORNING = datetime(2026, 11, 18, 7, 30, tzinfo=UTC)


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


def panel(tmp_path, width=640, height=480):
    from PIL import Image

    path = tmp_path / "render.png"
    Image.new("RGB", (width, height), (210, 180, 120)).save(path)
    return path


def test_the_box_carries_the_forecast_words_and_both_temperatures():
    box = forecast_box(weather(), date(2026, 11, 18), ())

    assert box.weather_words == "Rain, wet ground"
    assert box.high == "Hi 7.5°"
    assert box.low == "Lo 1.5°"
    assert box.date_line == "Wed 18 Nov"
    assert box.occasion is None


def test_an_occasion_makes_the_third_line_and_no_occasion_adds_nothing():
    with_one = forecast_box(weather(), date(2026, 11, 8), (Occasion("Diwali/Deepavali", all_day=True),))
    without = forecast_box(weather(), date(2026, 11, 8), ())

    assert with_one.lines()[-1] == "Diwali/Deepavali"
    assert len(without.lines()) == len(with_one.lines()) - 1


def test_the_words_and_the_numbers_cannot_disagree_because_they_share_a_source():
    """The three-word line is derived from the same summary the plate prints."""
    box = forecast_box(weather(summary="snow", precipitation_mm=0.0, precipitation_probability_pct=0),
                       date(2026, 11, 18), ())

    assert box.weather_words == "Snow falling"


def test_the_overlay_returns_a_png_that_was_actually_drawn_on(tmp_path):
    source = panel(tmp_path)
    before = source.read_bytes()

    out = overlay_forecast(source, weather(), date(2026, 11, 18), ())

    assert out[:8] == b"\x89PNG\r\n\x1a\n"
    assert out != before, "a plate over a flat field still changes pixels"
    assert struct.unpack(">II", out[16:24]) == (640, 480), "the panel keeps its size"


def test_the_overlay_leaves_its_input_alone(tmp_path):
    source = panel(tmp_path)
    before = source.read_bytes()

    overlay_forecast(source, weather(), date(2026, 11, 18), ())

    # The stage returns bytes and writes nothing; whether the raw render
    # survives is the pipeline's decision, not this function's.
    assert source.read_bytes() == before
