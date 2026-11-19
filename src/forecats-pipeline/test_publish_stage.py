"""Publishing is where the pipeline becomes three files a stranger can read."""

import json
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest
from conftest import MORNING
from forecats_pipeline.contracts import Caption, DayContext, Occasion, Staleness, WeatherToday
from forecats_pipeline.publish_stage import (
    FRESHNESS_NAME,
    existing_panel,
    panel_name,
    provenance_name,
    publish_panel,
    read_freshness,
)
from forecats_pipeline.render_stage import Rendered

PAYLOADS = {"https://api.open-meteo.com/v1/forecast?x=1": {"daily": {"time": ["2026-03-08"]}}}


def weather() -> WeatherToday:
    return WeatherToday(
        summary="rain",
        temperature_high_c=7.5,
        temperature_low_c=1.5,
        precipitation_mm=12.0,
        precipitation_probability_pct=90,
        is_daylight_at_panel_time=True,
        source="open-meteo",
        fetched_at=MORNING,
    )


def context() -> DayContext:
    return DayContext(
        for_day=date(2026, 3, 8),
        timezone="America/New_York",
        weather=weather(),
        occasions=(Occasion("Birthday dinner", all_day=False),),
    )


def caption() -> Caption:
    return Caption(text="a rainy street", template_hash="deadbeef0000", style="risograph")


def rendered(tmp_path: Path) -> Rendered:
    source = tmp_path / "scratch.png"
    source.write_bytes(b"\x89PNG\r\n\x1a\nfake")
    return Rendered(
        panel_path=source,
        renderer="sd-cli",
        seed=20260308,
        width_px=1024,
        height_px=1024,
        weights=("/var/lib/llama-models/h3image/minimax_h3_image_pruned-Q3_K_M.gguf",),
        reference_photos=(Path("/var/lib/forecats/refs/owner.png"),),
    )


def provenance(tmp_path: Path) -> dict:
    path = tmp_path / provenance_name(date(2026, 3, 8))
    return json.loads(path.read_text(encoding="utf-8"))


def test_the_sidecar_names_the_template_the_seed_the_weights_and_the_photos(tmp_path: Path):
    publish_panel(context(), caption(), rendered(tmp_path), {}, output_dir=tmp_path)

    record = provenance(tmp_path)
    assert record["template_hash"] == "deadbeef0000"
    assert record["seed"] == 20260308
    assert record["weights"] == ["/var/lib/llama-models/h3image/minimax_h3_image_pruned-Q3_K_M.gguf"]
    assert record["reference_photos"] == ["/var/lib/forecats/refs/owner.png"]


def test_the_sidecar_holds_the_payloads_the_sources_actually_sent(tmp_path: Path):
    publish_panel(context(), caption(), rendered(tmp_path), PAYLOADS, output_dir=tmp_path)

    record = provenance(tmp_path)
    assert record["payloads"] == PAYLOADS
    assert record["weather"]["source"] == "open-meteo"
    assert record["weather"]["fetched_at"] == MORNING.isoformat()
    assert record["occasions"] == [{"title": "Birthday dinner", "all_day": False, "described_as": None}]


def test_a_viewer_can_date_the_panel_that_is_hanging_up(tmp_path: Path):
    publish_panel(context(), caption(), rendered(tmp_path), {}, output_dir=tmp_path, published_at=MORNING)

    later = MORNING + timedelta(hours=30)
    staleness = read_freshness(tmp_path, now=later)

    assert staleness == Staleness(rendered_at=MORNING, age_hours=30.0)


def test_the_freshness_artefact_names_the_panel_it_is_about(tmp_path: Path):
    publish_panel(context(), caption(), rendered(tmp_path), {}, output_dir=tmp_path, published_at=MORNING)

    record = json.loads((tmp_path / FRESHNESS_NAME).read_text(encoding="utf-8"))
    assert record["panel"] == panel_name(date(2026, 3, 8))
    assert record["rendered_at"] == MORNING.isoformat()


def test_a_panel_already_on_disk_is_found_by_its_date(tmp_path: Path):
    assert existing_panel(date(2026, 3, 8), tmp_path) is None

    (tmp_path / panel_name(date(2026, 3, 8))).write_bytes(b"\x89PNG\r\n\x1a\n")

    assert existing_panel(date(2026, 3, 8), tmp_path) is not None
    assert existing_panel(date(2026, 3, 9), tmp_path) is None


def test_a_clock_without_a_zone_cannot_claim_a_render_time(tmp_path: Path):
    naive = datetime(2026, 3, 8, 3, 0, tzinfo=None)

    with pytest.raises(ValueError, match="timezone-aware"):
        publish_panel(context(), caption(), rendered(tmp_path), {}, output_dir=tmp_path, published_at=naive)


def test_freshness_cannot_be_read_against_a_naive_clock(tmp_path: Path):
    publish_panel(context(), caption(), rendered(tmp_path), {}, output_dir=tmp_path, published_at=MORNING)

    naive_now = datetime(2026, 3, 9).replace(tzinfo=None)

    with pytest.raises(ValueError, match="timezone-aware"):
        read_freshness(tmp_path, now=naive_now)
