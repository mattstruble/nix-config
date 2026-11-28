"""Publishing is where the pipeline becomes the files a stranger can read.

The sidecar, the prompt artefact, the freshness record and the gallery are all
written here, and only two of them may ever be served: what separates the public
ones from the private one is that nothing published is a path, an address or a
mailbox.
"""

import json
from datetime import date, datetime, timedelta
from pathlib import Path

import pytest
from conftest import DAY, MORNING, REPORT_INBOX, gradient_png
from forecats_pipeline import publish_stage
from forecats_pipeline.contracts import (
    Caption,
    DayContext,
    Occasion,
    Published,
    Scene,
    Staleness,
    WeatherToday,
)
from forecats_pipeline.publish_stage import (
    BANNER_ASPECT,
    FRESHNESS_NAME,
    GALLERY_NAME,
    THUMB_MAX_PX,
    banner_name,
    existing_panel,
    panel_name,
    prompt_name,
    provenance_name,
    publish_panel,
    read_freshness,
    read_gallery,
    thumb_name,
)
from forecats_pipeline.render_stage import REPORT_ADDRESS_ENV, Rendered
from PIL import Image

PAYLOADS = {"api.open-meteo.com": {"daily": {"time": ["2026-03-08"]}}}

# The scene the caption was written from, and so the activity the prompt artefact
# publishes: the pipeline hands the publish the scene it drew the caption from, so
# a day's page names the words that were actually sent.
SCENE = Scene(
    activity="an ambush from behind the sofa",
    foreground="two cats and a feather wand",
    background="a sunlit living room",
)

WEIGHT = "/var/lib/llama-models/h3image/minimax_h3_image_pruned-Q3_K_M.gguf"
REFERENCE_PHOTO = "/var/lib/forecats/refs/owner.png"
FEED_ADDRESS = "https://cloud.example.invalid/dav/public-calendars/token-abc123?export"

# What the provenance sidecar holds and the prompt artefact must not: the two
# paths the render read, the address a viewer writes to, the feed address a
# payload could be filed under.
PRIVATE = (REPORT_INBOX, WEIGHT, REFERENCE_PHOTO, FEED_ADDRESS)


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


def context(day: date = DAY) -> DayContext:
    return DayContext(
        for_day=day,
        timezone="America/New_York",
        weather=weather(),
        occasions=(Occasion("Birthday dinner", all_day=False),),
    )


def caption() -> Caption:
    return Caption(text="a rainy street", template_hash="deadbeef0000", style="risograph")


def rendered(tmp_path: Path, *, size: int = 64) -> Rendered:
    tmp_path.mkdir(parents=True, exist_ok=True)
    source = tmp_path / "scratch.png"
    source.write_bytes(gradient_png(size))
    return Rendered(
        panel_path=source,
        renderer="sd-cli",
        seed=20260308,
        width_px=size,
        height_px=size,
        weights=(WEIGHT,),
        reference_photos=(Path(REFERENCE_PHOTO),),
    )


def publish(tmp_path: Path, *, day: date = DAY, panel: Rendered | None = None, **over) -> Published:
    """One day published into `tmp_path`, with the run's own scene and variants."""
    over.setdefault("report_address", REPORT_INBOX)
    payloads = over.pop("payloads", {})
    return publish_panel(
        context(day),
        caption(),
        panel or rendered(tmp_path),
        payloads,
        scene=SCENE,
        output_dir=tmp_path,
        **over,
    )


def provenance(tmp_path: Path, day: date = DAY) -> dict:
    return json.loads((tmp_path / provenance_name(day)).read_text(encoding="utf-8"))


def prompt(tmp_path: Path, day: date = DAY) -> dict:
    return json.loads((tmp_path / prompt_name(day)).read_text(encoding="utf-8"))


def prompt_text(tmp_path: Path, day: date = DAY) -> str:
    return (tmp_path / prompt_name(day)).read_text(encoding="utf-8")


def strings(record: object):
    """Every string in a decoded artefact, however deep in it it sits."""
    if isinstance(record, str):
        yield record
    elif isinstance(record, dict):
        for value in record.values():
            yield from strings(value)
    elif isinstance(record, list):
        for value in record:
            yield from strings(value)


def image_size(path: Path) -> tuple[int, int]:
    with Image.open(path) as image:
        return image.size


def left_edge(path: Path) -> list[tuple[int, int, int]]:
    """The pixels down a picture's left edge, which is what a crop cannot change."""
    with Image.open(path) as image:
        return [image.getpixel((0, y)) for y in range(image.height)]


def test_the_sidecar_names_the_template_the_seed_the_weights_and_the_photos(tmp_path: Path):
    publish(tmp_path)

    record = provenance(tmp_path)
    assert record["template_hash"] == "deadbeef0000"
    assert record["seed"] == 20260308
    assert record["weights"] == [WEIGHT]
    assert record["reference_photos"] == [REFERENCE_PHOTO]


def test_the_sidecar_holds_the_payloads_the_sources_actually_sent(tmp_path: Path):
    publish(tmp_path, payloads=PAYLOADS)

    record = provenance(tmp_path)
    assert record["payloads"] == PAYLOADS
    assert record["weather"]["source"] == "open-meteo"
    assert record["weather"]["fetched_at"] == MORNING.isoformat()
    assert record["occasions"] == [{"title": "Birthday dinner", "all_day": False, "described_as": None}]


def test_a_payload_filed_under_its_address_is_not_published(tmp_path: Path):
    """The sidecar is served to whoever can see the panel, so the write refuses.

    The message counts the offending entries without quoting one: the key it is
    complaining about is the calendar's read token.
    """
    with pytest.raises(ValueError, match="feed label") as refusal:
        publish(tmp_path, payloads={FEED_ADDRESS: "ics"})

    assert "token-abc123" not in str(refusal.value)
    assert list(tmp_path.glob("*.provenance.json")) == []


def test_the_sidecar_names_where_to_report_a_panel_that_should_not_exist(tmp_path: Path):
    """The grant obliges a way to report a violation, and the sidecar is what a viewer reads.

    The address is emitted rather than only stored: nothing else beside the PNG
    says who to tell, and a viewer with a complaint has the panel and this file.
    """
    publish(tmp_path)

    assert provenance(tmp_path)["report_address"] == REPORT_INBOX


def test_nothing_is_published_where_nobody_can_report_it(tmp_path: Path):
    """A blank address is no report mechanism, so the write refuses and takes the panel back."""
    with pytest.raises(ValueError, match=REPORT_ADDRESS_ENV):
        publish(tmp_path, report_address="")

    assert list(tmp_path.glob("panel-*")) == []
    assert list(tmp_path.glob("*.json")) == []


def test_a_sidecar_that_cannot_be_written_leaves_no_panel_on_the_wall(tmp_path, monkeypatch):
    """The panel is the last file to appear, and that order is the obligation.

    A published PNG with no sidecar is a picture nobody can explain or report, and
    the nightly cannot notice: a second run for the date finds the panel and skips.
    Failing the other way round costs a sidecar naming a panel that never arrived
    and a render still under its scratch name, both of which the next run replaces.
    """
    writes = publish_stage._write_json

    def sidecar_that_fails(path, record):
        if str(path).endswith(provenance_name(DAY)):
            raise OSError(28, "No space left on device")
        writes(path, record)

    monkeypatch.setattr(publish_stage, "_write_json", sidecar_that_fails)

    with pytest.raises(OSError, match="No space left"):
        publish(tmp_path)

    assert list(tmp_path.glob("panel-*")) == []
    assert (tmp_path / "scratch.png").is_file()


def test_a_variant_that_cannot_be_cut_leaves_no_panel_on_the_wall(tmp_path, monkeypatch):
    """The renditions come off the render's scratch bytes, before the panel is named.

    A banner that failed to be cut costs a sidecar naming a panel that never
    arrived, which is the failure the nightly already tolerates: nothing is listed,
    nothing is served, and the next run for the date writes them again. The panel
    is the file that must not appear, because a second run would find it and skip.
    """

    def no_crop(source, day, output_dir):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(publish_stage, "_write_variants", no_crop)

    with pytest.raises(OSError, match="No space left"):
        publish(tmp_path)

    assert list(tmp_path.glob("panel-*.png")) == []
    assert not (tmp_path / GALLERY_NAME).exists()
    assert (tmp_path / "scratch.png").is_file()


def test_a_variant_that_cannot_be_saved_takes_the_other_ones_scratch_with_it(tmp_path, monkeypatch):
    """Both renditions are renamed only once both are written.

    A save that fails halfway is the state this exists to refuse: a banner beside no
    thumbnail is a day half published, and no later run for the date returns to it.
    """
    save = Image.Image.save

    def thumbnail_that_fails(self, fp, *args, **kwargs):
        if thumb_name(DAY) in str(fp):
            raise OSError(28, "No space left on device")
        return save(self, fp, *args, **kwargs)

    monkeypatch.setattr(Image.Image, "save", thumbnail_that_fails)

    with pytest.raises(OSError, match="No space left"):
        publish(tmp_path)

    assert not (tmp_path / banner_name(DAY)).exists()
    assert not (tmp_path / thumb_name(DAY)).exists()
    assert list(tmp_path.glob("*.tmp")) == []


def test_a_viewer_can_date_the_panel_that_is_hanging_up(tmp_path: Path):
    publish(tmp_path, published_at=MORNING)

    later = MORNING + timedelta(hours=30)
    staleness = read_freshness(tmp_path, now=later)

    assert staleness == Staleness(rendered_at=MORNING, age_hours=30.0)


def test_the_freshness_artefact_names_the_panel_it_is_about(tmp_path: Path):
    publish(tmp_path, published_at=MORNING)

    record = json.loads((tmp_path / FRESHNESS_NAME).read_text(encoding="utf-8"))
    assert record["panel"] == panel_name(DAY)
    assert record["rendered_at"] == MORNING.isoformat()


def test_a_panel_already_on_disk_is_found_by_its_date(tmp_path: Path):
    assert existing_panel(DAY, tmp_path) is None

    (tmp_path / panel_name(DAY)).write_bytes(b"\x89PNG\r\n\x1a\n")

    assert existing_panel(DAY, tmp_path) is not None
    assert existing_panel(date(2026, 3, 9), tmp_path) is None


def test_a_clock_without_a_zone_cannot_claim_a_render_time(tmp_path: Path):
    naive = datetime(2026, 3, 8, 3, 0, tzinfo=None)

    with pytest.raises(ValueError, match="timezone-aware"):
        publish(tmp_path, published_at=naive)


def test_freshness_cannot_be_read_against_a_naive_clock(tmp_path: Path):
    publish(tmp_path, published_at=MORNING)

    naive_now = datetime(2026, 3, 9).replace(tzinfo=None)

    with pytest.raises(ValueError, match="timezone-aware"):
        read_freshness(tmp_path, now=naive_now)


def test_the_names_the_page_fetches_are_the_names_the_publish_writes(tmp_path: Path):
    """Exact, because a page that guesses a name 404s and a server that lists is refused."""
    assert panel_name(DAY) == "panel-2026-03-08.png"
    assert banner_name(DAY) == "panel-2026-03-08-banner.png"
    assert thumb_name(DAY) == "panel-2026-03-08-thumb.png"
    assert prompt_name(DAY) == "panel-2026-03-08.prompt.json"

    publish(tmp_path)

    for name in (
        panel_name(DAY),
        banner_name(DAY),
        thumb_name(DAY),
        prompt_name(DAY),
        provenance_name(DAY),
        FRESHNESS_NAME,
        GALLERY_NAME,
    ):
        assert (tmp_path / name).is_file(), name


def test_the_banner_is_a_band_cut_from_the_panel_and_not_a_second_render(tmp_path: Path):
    published = publish(tmp_path)

    banner = tmp_path / banner_name(DAY)
    band = left_edge(banner)
    edge = left_edge(published.panel_path)

    assert image_size(banner)[1] < image_size(published.panel_path)[1]
    assert abs(image_size(banner)[0] - image_size(banner)[1] * BANNER_ASPECT) <= 1
    # Every pixel of the banner is a pixel of the panel, in one run of the panel's
    # own rows: a crop. A redraw could not promise that, and would not be free.
    assert any(edge[i : i + len(band)] == band for i in range(len(edge) - len(band) + 1))


def test_the_thumbnail_is_the_panel_smaller_and_never_bigger(tmp_path: Path):
    big = tmp_path / "big"
    publish(big, panel=rendered(big, size=1024))
    assert image_size(big / thumb_name(DAY)) == (THUMB_MAX_PX, THUMB_MAX_PX)

    small = tmp_path / "small"
    publish(small, panel=rendered(small, size=64))
    assert image_size(small / thumb_name(DAY)) == (64, 64)


def test_the_gallery_lists_every_day_the_volume_holds(tmp_path: Path):
    publish(tmp_path, day=date(2026, 3, 7))
    publish(tmp_path, day=date(2026, 3, 8))

    gallery = read_gallery(tmp_path)

    assert [entry["day"] for entry in gallery["days"]] == ["2026-03-08", "2026-03-07"]
    assert gallery["days"][0]["variants"] == {
        "full": "panel-2026-03-08.png",
        "banner": "panel-2026-03-08-banner.png",
        "thumb": "panel-2026-03-08-thumb.png",
    }
    assert gallery["days"][0]["prompt"] == "panel-2026-03-08.prompt.json"


def test_a_day_missing_a_variant_lists_only_the_variants_it_holds(tmp_path: Path):
    """A day drawn before a variant existed is a day with the variants it has.

    Naming a file the volume does not hold turns one interrupted nightly into a
    broken image on every page that reads the index.
    """
    earlier = date(2026, 3, 7)
    publish(tmp_path, day=earlier)
    (tmp_path / banner_name(earlier)).unlink()

    publish(tmp_path)

    record = read_gallery(tmp_path)["days"][1]
    assert record["day"] == "2026-03-07"
    assert sorted(record["variants"]) == ["full", "thumb"]


def test_a_banner_is_not_a_day(tmp_path: Path):
    """The index is built from full panels; a variant hangs off a day, it is not one."""
    (tmp_path / "panel-2026-03-09-banner.png").write_bytes(gradient_png(8))
    (tmp_path / "panel-2026-13-45.png").write_bytes(gradient_png(8))

    publish(tmp_path)

    assert [entry["day"] for entry in read_gallery(tmp_path)["days"]] == ["2026-03-08"]


def test_the_retention_window_is_a_value_and_not_a_deletion(tmp_path, monkeypatch):
    """The volume keeps every panel; a window only decides what the index names."""
    publish(tmp_path, day=date(2026, 3, 6))
    publish(tmp_path, day=date(2026, 3, 7))

    monkeypatch.setattr(publish_stage, "RETAINED_PANEL_DAYS", 1)
    publish(tmp_path, day=date(2026, 3, 8))

    gallery = read_gallery(tmp_path)
    assert [entry["day"] for entry in gallery["days"]] == ["2026-03-08"]
    assert gallery["retained_days"] == 1
    assert (tmp_path / panel_name(date(2026, 3, 6))).is_file()


def test_the_prompt_artefact_is_the_public_half_of_the_sidecar(tmp_path: Path):
    publish(tmp_path)

    assert prompt(tmp_path) == {
        "for_day": "2026-03-08",
        "prompt": "a rainy street",
        "seed": 20260308,
        "style": "risograph",
        "activity": "an ambush from behind the sofa",
        "weather_words": "Rain, wet ground",
        "occasion": "Birthday dinner",
    }


def test_the_prompt_artefact_holds_no_path_and_no_report_address(tmp_path: Path):
    """The assertion that decides whether this file may be served at all.

    The sidecar written by the same call holds every string on this list, and the
    viewer refuses to serve it. The artefact is the curated counterpart, so the
    line is not a blacklist of paths: nothing published is a path, an address or a
    mailbox, whatever the caption happens to be about.
    """
    publish(tmp_path, payloads=PAYLOADS)

    published = prompt_text(tmp_path)
    for private in PRIVATE:
        assert private not in published

    for value in strings(prompt(tmp_path)):
        assert not value.startswith("/"), value
        assert "@" not in value, value
        assert "://" not in value, value

    sidecar = (tmp_path / provenance_name(DAY)).read_text(encoding="utf-8")
    assert REPORT_INBOX in sidecar
    assert REFERENCE_PHOTO in sidecar


def test_a_day_with_no_sky_publishes_no_weather_words(tmp_path: Path):
    """A refused sky has no words to publish, and the artefact says so rather than inventing."""
    skyless = DayContext(
        for_day=DAY,
        timezone="America/New_York",
        weather=None,
        weather_refusals=("open-meteo was unreachable",),
    )

    publish_panel(
        skyless,
        caption(),
        rendered(tmp_path),
        {},
        scene=SCENE,
        output_dir=tmp_path,
        report_address=REPORT_INBOX,
    )

    assert prompt(tmp_path)["weather_words"] is None
