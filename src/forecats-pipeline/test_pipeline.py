"""The chain end to end: one run publishes, the next one for the date does not.

The weather provider is a stub and the renderer is the fake; the calendar is
the real ICS provider over the real fixture. No test in this file needs a GPU,
a network route, or a credential.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

import day_context
import forecats_pipeline
from conftest import DAY, DAY_ICS, FEED_URL, MORNING, StubFeed, StubWeatherProvider, two_pets
from day_context import (
    FailureKind,
    Fetched,
    Location,
    ProviderFailure,
    WeatherCondition,
    WeatherDay,
)
from forecats_pipeline.calendar_feeds import MultiFeedCalendarProvider
from forecats_pipeline.contracts import PipelineRefusal
from forecats_pipeline.day_context_stage import PayloadLog, RecordingFetcher
from forecats_pipeline.contracts import Published
from forecats_pipeline.pipeline import CALENDAR_FEEDS_ENV, Skipped, main, run_nightly
from forecats_pipeline.publish_stage import FRESHNESS_NAME, panel_name, provenance_name
from forecats_pipeline.render_stage import FakeRenderer, SdCliSettings

# The two source trees, as the interpreter running the suite found them: the
# subprocess tests below start the entry point the way the package's wrapper does.
SOURCE_ROOTS = os.pathsep.join(
    str(Path(module.__file__).parent.parent) for module in (day_context, forecats_pipeline)
)

# A stand-in for the diffusion CLI: it records what it was asked for and writes
# the picture it was promised. `sys.executable` rather than `/bin/sh` because a
# shebang has to name an interpreter that exists wherever the suite runs.
FAKE_CLI = '''#!{interpreter}
import json, os, pathlib, sys

argv = sys.argv[1:]
pathlib.Path(argv[argv.index("-o") + 1]).write_bytes(bytes([137, 80, 78, 71, 13, 10, 26, 10]))
pathlib.Path(os.environ["FAKE_CLI_LOG"]).write_text(json.dumps({{
    "argv": argv,
    "cuda_visible_devices": os.environ.get("CUDA_VISIBLE_DEVICES"),
    "nvidia_visible_devices": os.environ.get("NVIDIA_VISIBLE_DEVICES"),
}}), encoding="utf-8")
'''

# Read by the pipeline from its environment, and absent from a render pod: no
# model to ask, no key, no SSH agent whose socket a stray `ssh` could find.
POD_REMOVED_ENV = (
    "LITELLM_API_KEY",
    "FORECATS_RESEARCH_ENDPOINT",
    "SSH_AUTH_SOCK",
    "SSH_CONNECTION",
    "SSH_KEY_PATH",
    "GIT_SSH_COMMAND",
)

# The label the one feed of `collaborators()` is configured under, and so the
# name its payload is published under.
FEED_LABEL = "day feed"


def collaborators() -> dict:
    log = PayloadLog({FEED_URL: FEED_LABEL})
    feed = RecordingFetcher(StubFeed(text=DAY_ICS.read_text(encoding="utf-8")), log)
    sky = StubWeatherProvider("open-meteo", _rain())
    return {
        "weather_providers": [sky],
        "calendar_provider": MultiFeedCalendarProvider(feed, ((FEED_LABEL, FEED_URL),)),
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


def nightly_argv(output_dir: Path, day: str = DAY.isoformat()) -> list[str]:
    """The entry point's arguments for a run meant to stop before it renders."""
    return [
        "--day",
        day,
        "--timezone",
        "America/New_York",
        "--latitude",
        "40.7128",
        "--longitude",
        "-74.006",
        "--output-dir",
        str(output_dir),
    ]


# A feed address is a credential, so these two constants are what the refusal
# tests below are really about: nothing carrying the token may be printed.
PRIVATE_FEED_URL = "https://caldav.example.invalid/e/token-abc123/basic.ics"
FEED_TOKEN = "token-abc123"  # pragma: allowlist secret


def run(output_dir: Path, **over):
    parts = {**collaborators(), **over}
    return run_nightly(DAY, place(), published_at=MORNING, output_dir=output_dir, **parts)


def household_file(tmp_path: Path) -> Path:
    path = tmp_path / "household.yaml"
    path.write_text(
        "pets:\n  - name: Milo\n    reference_photo: /refs/milo.jpg\n"
        "    visual_description: a ginger tabby\n",
        encoding="utf-8",
    )
    return path


def run_entry_point(tmp_path: Path, monkeypatch, capsys, feeds: str) -> None:
    """One nightly through the entry point, or the line it refused with.

    Nothing here reaches the host: the feeds are `file:` URLs, the sky is
    `--weather`, and the model endpoint the developer's shell may have set is
    removed, as it is on a render pod.
    """
    monkeypatch.setenv(CALENDAR_FEEDS_ENV, feeds)
    for name in POD_REMOVED_ENV:
        monkeypatch.delenv(name, raising=False)

    exit_code = main(
        nightly_argv(tmp_path / "panels")
        + ["--household-file", str(household_file(tmp_path)), "--weather", "rain"]
    )
    printed = capsys.readouterr().out
    assert exit_code == 0, printed


def sidecar(tmp_path: Path) -> dict:
    path = tmp_path / "panels" / provenance_name(DAY)
    return json.loads(path.read_text(encoding="utf-8"))


def one_event_ics(summary: str) -> str:
    """A calendar holding one all-day event, so two feeds' bodies differ."""
    return (
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//x//x//EN\r\n"
        "BEGIN:VEVENT\r\n"
        f"UID:{summary.replace(' ', '-').lower()}@x\r\n"
        "DTSTART;VALUE=DATE:20260308\r\n"
        f"SUMMARY:{summary}\r\n"
        "END:VEVENT\r\nEND:VCALENDAR\r\n"
    )


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


def test_the_sidecar_names_a_private_feed_by_its_label_not_its_address(
    tmp_path, monkeypatch, capsys
):
    """The sidecar is served to whoever can see the panel, and the address is the calendar.

    A private feed carries its read token in its path, so a payload published
    under the URL it was fetched from publishes the household's calendar beside
    the picture of a cat.
    """
    feed = tmp_path / "dav" / FEED_TOKEN / "basic.ics"
    feed.parent.mkdir(parents=True)
    feed.write_text(DAY_ICS.read_text(encoding="utf-8"), encoding="utf-8")

    run_entry_point(tmp_path, monkeypatch, capsys, f"family={feed.as_uri()}")

    on_disk = (tmp_path / "panels" / provenance_name(DAY)).read_text(encoding="utf-8")
    assert FEED_TOKEN not in on_disk
    payloads = json.loads(on_disk)["payloads"]
    assert list(payloads) == ["family"]
    assert "BEGIN:VCALENDAR" in payloads["family"]


def test_two_feeds_sharing_a_label_are_published_as_two_payloads(tmp_path, monkeypatch, capsys):
    """Two feeds under one label are two sources; the sidecar holds neither in place of the other."""
    feeds = []
    for name, summary in (("vet", "Vet check"), ("groomer", "Grooming")):
        feed = tmp_path / f"{name}.ics"
        feed.write_text(one_event_ics(summary), encoding="utf-8")
        feeds.append(f"home={feed.as_uri()}")

    run_entry_point(tmp_path, monkeypatch, capsys, ",".join(feeds))

    payloads = sidecar(tmp_path)["payloads"]
    assert sorted(payloads) == ["home", "home#2"]
    published = json.dumps(payloads)
    assert "Vet check" in published
    assert "Grooming" in published


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


def test_a_malformed_feed_is_refused_without_quoting_its_url(tmp_path, monkeypatch, capsys):
    """A bare feed address is what `label=url` rejects, and the address is the secret.

    The nightly leaves one line in a log that outlives the Secret quoting it
    would publish, so the refusal names the variable and points at the pair.
    """
    monkeypatch.setenv(CALENDAR_FEEDS_ENV, PRIVATE_FEED_URL)

    exit_code = main(nightly_argv(tmp_path / "panels"))

    printed = capsys.readouterr().out
    assert exit_code == 1
    assert f"refused at config: {CALENDAR_FEEDS_ENV} pair 1 is not one label=url pair" in printed
    assert FEED_TOKEN not in printed
    assert "unhandled" not in printed


def test_a_malformed_pair_after_a_good_one_is_named_by_its_position(tmp_path, monkeypatch, capsys):
    """Naming which pair failed is not a licence to name the variable's value."""
    monkeypatch.setenv(CALENDAR_FEEDS_ENV, f"home={DAY_ICS.as_uri()},{PRIVATE_FEED_URL}")

    exit_code = main(nightly_argv(tmp_path / "panels"))

    printed = capsys.readouterr().out
    assert exit_code == 1
    assert "pair 2" in printed
    assert FEED_TOKEN not in printed
    assert DAY_ICS.as_uri() not in printed


def test_a_day_that_is_not_a_date_names_the_flag_instead_of_the_failure(tmp_path, capsys):
    """`Invalid isoformat string` is a message about the code; the typo is in a flag."""
    exit_code = main(nightly_argv(tmp_path / "panels", day="not-a-date"))

    printed = capsys.readouterr().out
    assert exit_code == 1
    assert (
        "refused at usage: --day wants an ISO date such as 2026-03-08, got 'not-a-date'" in printed
    )
    assert "isoformat" not in printed
    assert "unhandled" not in printed


def test_the_entry_point_renders_with_no_host_and_no_ssh_credentials(tmp_path: Path):
    """The nightly path, in an environment shaped like the render pod.

    `PATH` holds the diffusion CLI and nothing else, so a renderer that still
    shelled out to `ssh` or `scp` would not have found them. `HOME` is an empty
    directory, so there is no key to fall back to even if it did. The card is the
    pod's, named by `NVIDIA_VISIBLE_DEVICES`.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    fake_cli = bin_dir / "sd-cli"
    fake_cli.write_text(FAKE_CLI.format(interpreter=sys.executable), encoding="utf-8")
    fake_cli.chmod(0o755)
    log = tmp_path / "cli.json"

    weights = tmp_path / "h3image"
    settings = SdCliSettings.for_directory(weights)
    weights.mkdir()
    for name in settings.files:
        Path(name).write_bytes(b"the bytes of a weight")

    pictures = tmp_path / "photos"
    pictures.mkdir()
    for name in ("milo.jpg", "mochi.jpg"):
        pictures.joinpath(name).write_bytes(b"\xff\xd8\xff\xe0")
    household = tmp_path / "household.yaml"
    entries = "".join(
        f"  - name: {name}\n"
        "    visual_description: a ginger tabby with a look of its own\n"
        f"    reference_photo: {pictures / f'{name.lower()}.jpg'}\n"
        for name in ("Milo", "Mochi")
    )
    household.write_text(f"pets:\n{entries}", encoding="utf-8")

    home = tmp_path / "home"
    home.mkdir()
    environment = {
        key: value
        for key, value in os.environ.items()
        if key not in POD_REMOVED_ENV and key not in {"PATH", "HOME", "PYTHONPATH"}
    } | {
        "PATH": str(bin_dir),
        "HOME": str(home),
        "PYTHONPATH": SOURCE_ROOTS,
        "PYTHONDONTWRITEBYTECODE": "1",
        "FAKE_CLI_LOG": str(log),
        "NVIDIA_VISIBLE_DEVICES": "1",
        CALENDAR_FEEDS_ENV: f"home={DAY_ICS.as_uri()}",
    }

    run = subprocess.run(
        [
            sys.executable,
            "-m",
            "forecats_pipeline",
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
            "--renderer",
            "sd-cli",
            "--model-directory",
            str(weights),
            "--weather",
            "snow",
            "--high",
            "1",
            "--low",
            "-3",
        ],
        capture_output=True,
        text=True,
        env=environment,
        check=False,
    )

    assert run.returncode == 0, run.stdout + run.stderr
    assert (tmp_path / "panels" / panel_name(DAY)).is_file()

    asked = json.loads(log.read_text(encoding="utf-8"))
    assert asked["nvidia_visible_devices"] == "1"
    assert asked["cuda_visible_devices"] is None
    assert asked["argv"].count("-r") == 2

    record = json.loads((tmp_path / "panels" / provenance_name(DAY)).read_text(encoding="utf-8"))
    assert record["renderer"] == "sd-cli"
    assert record["weights"] == [settings.diffusion_model, settings.vae, settings.text_encoder]
    assert record["reference_photos"] == [
        str(pictures / "milo.jpg"),
        str(pictures / "mochi.jpg"),
    ]
