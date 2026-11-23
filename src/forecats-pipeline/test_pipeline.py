"""The chain end to end: one run publishes, the next one for the date does not.

The weather provider is a stub and the renderer is the fake; the calendar is
the real ICS provider over the real fixture. No test in this file needs a GPU,
a network route, or a credential.
"""

from pathlib import Path

from conftest import DAY, DAY_ICS, FEED_URL, MORNING, StubFeed, StubWeatherProvider, two_pets
from day_context import (
    FailureKind,
    Fetched,
    Location,
    ProviderFailure,
    WeatherCondition,
    WeatherDay,
)
from day_context.schedule_ics import IcsCalendarProvider
from forecats_pipeline.contracts import PipelineRefusal
from forecats_pipeline.day_context_stage import PayloadLog, RecordingFetcher
from forecats_pipeline.contracts import Published
from forecats_pipeline.pipeline import CALENDAR_FEEDS_ENV, Skipped, main, run_nightly
from forecats_pipeline.publish_stage import FRESHNESS_NAME, panel_name
from forecats_pipeline.render_stage import FakeRenderer


def collaborators() -> dict:
    log = PayloadLog()
    feed = RecordingFetcher(StubFeed(text=DAY_ICS.read_text(encoding="utf-8")), log)
    sky = StubWeatherProvider("open-meteo", _rain())
    return {
        "weather_providers": [sky],
        "calendar_provider": IcsCalendarProvider(feed, FEED_URL),
        "renderer": FakeRenderer(weights=("/var/lib/llama-models/h3image/model.gguf",)),
        "payloads": log,
        "household": two_pets(),
    }


def _rain() -> Fetched[WeatherDay]:
    return Fetched(
        value=WeatherDay(
            day=DAY,
            condition=WeatherCondition.RAIN,
            temperature_min_c=1.0,
            temperature_max_c=7.5,
            precipitation_mm=12.0,
            precipitation_probability_pct=90,
        ),
        source="open-meteo",
        fetched_at=MORNING,
    )


def place() -> Location:
    return Location("New York", 40.7128, -74.006, "America/New_York")


def run(output_dir: Path, **over):
    parts = {**collaborators(), **over}
    return run_nightly(DAY, place(), published_at=MORNING, output_dir=output_dir, **parts)


def test_one_run_publishes_the_panel_the_sidecar_and_the_freshness_file(tmp_path: Path):
    published = run(tmp_path)

    assert (tmp_path / panel_name(DAY)).is_file()
    assert published.provenance_path.endswith(".provenance.json")
    assert Path(published.provenance_path).is_file()
    assert (tmp_path / FRESHNESS_NAME).is_file()


def test_the_sidecar_records_the_feed_that_was_read(tmp_path: Path):
    published = run(tmp_path)

    record = Path(published.provenance_path).read_text(encoding="utf-8")
    assert "BEGIN:VCALENDAR" in record
    assert "open-meteo" in record


def test_the_second_run_for_the_same_date_skips_and_says_why(tmp_path: Path):
    first = run(tmp_path)
    panel = tmp_path / panel_name(DAY)
    before = panel.read_bytes()

    second = run(tmp_path)

    assert isinstance(second, Skipped)
    assert second.for_day == DAY
    assert "already published" in second.reason
    assert panel.read_bytes() == before
    assert Path(first.provenance_path).is_file()


def test_a_day_with_no_sky_is_refused_and_nothing_is_published(tmp_path: Path):
    outcome = run(
        tmp_path,
        weather_providers=[
            StubWeatherProvider("open-meteo", ProviderFailure("open-meteo", FailureKind.UNREACHABLE, "dns"))
        ],
    )

    assert isinstance(outcome, PipelineRefusal)
    assert outcome.stage == "weather"
    assert list(tmp_path.iterdir()) == []


def test_a_first_run_creates_the_directory_it_publishes_into(tmp_path):
    """The renderer writes into the output directory, so a fresh host must not
    pay for a two-minute render before finding out it does not exist."""
    fresh = tmp_path / "not" / "made" / "yet"

    outcome = run(fresh)

    assert fresh.is_dir()
    assert isinstance(outcome, Published)


def test_a_failure_no_stage_claimed_still_leaves_a_refusal_with_its_cause(
    tmp_path, monkeypatch, capsys
):
    """Nobody reads the nightly's output until the wall has been wrong for a
    week, so the one line it leaves has to hold the reason by itself."""
    household = tmp_path / "household.yaml"
    household.write_text(
        "pets:\n  - name: Milo\n    reference_photo: /refs/milo.jpg\n"
        "    visual_description: ginger tabby\n",
        encoding="utf-8",
    )

    def disk_full(*args, **kwargs):
        raise OSError(28, "No space left on device")

    monkeypatch.setenv(CALENDAR_FEEDS_ENV, f"home={FEED_URL}")
    monkeypatch.setattr("forecats_pipeline.pipeline.run_nightly", disk_full)

    exit_code = main(
        [
            "--day",
            DAY.isoformat(),
            "--timezone",
            "America/New_York",
            "--latitude",
            "40.7128",
            "--longitude",
            "-74.006",
            "--output-dir",
            str(tmp_path / "panels"),
            "--household-file",
            str(household),
        ]
    )

    printed = capsys.readouterr().out
    assert exit_code == 1
    assert "refused at pipeline: unhandled OSError: [Errno 28] No space left on device" in printed
