"""Stage 4: put the panel where it is read, and write down how it was made.

The panel is what the viewer sees, and the banner and the thumbnail are the same
picture at the shapes a page can hold — cropped and scaled from those bytes, so
what hangs on the wall and what loads in a banner are one drawing and not two.

The provenance sidecar is what makes a wrong picture explainable afterwards —
which template, which seed, which weights, which reference photos, and the raw
payload each source actually answered with, beside the address a viewer writes
to when they believe the picture should not exist. It is the private half, and
the prompt artefact beside the panel is its public counterpart: the words that
were the prompt, and the few facts the picture is a picture of, with no path and
no address in it. Nothing here serves the sidecar.

The freshness artefact is what makes a *stopped* pipeline visible: a panel that
has not been redrawn for nine days looks exactly like one that was, and the only
difference a viewer can see is the timestamp beside it. So the timestamp is
published as a separate, always-current file rather than being something a reader
has to trust the PNG about.

The gallery is what makes the volume a history rather than a wall: one file
naming every day the household holds a panel for and the renditions of it that
exist. It is written here, by the step that wrote the panel, and never by a
server listing the directory at request time — a listing names every date there
has a panel and serves the sidecar beside it, which is the thing the viewer's
whitelist exists to refuse.
"""

import json
import re
from dataclasses import asdict
from datetime import UTC, date, datetime
from os import replace
from pathlib import Path
from shutil import move

from PIL import Image

from forecats_pipeline.contracts import Caption, DayContext, Published, Scene, Staleness
from forecats_pipeline.overlay_stage import panel_occasion
from forecats_pipeline.render_stage import REPORT_ADDRESS_ENV, Rendered

__all__ = [
    "BANNER_ASPECT",
    "FRESHNESS_NAME",
    "GALLERY_NAME",
    "RETAINED_PANEL_DAYS",
    "THUMB_MAX_PX",
    "banner_name",
    "existing_panel",
    "panel_name",
    "prompt_name",
    "provenance_name",
    "publish_panel",
    "read_freshness",
    "read_gallery",
    "retained_days",
    "thumb_name",
    "variant_names",
]

FRESHNESS_NAME = "freshness.json"
GALLERY_NAME = "gallery.json"

# The volume keeps every panel, and the gallery lists every panel the volume
# keeps. A window is a value here rather than a change here: set it to N and the
# gallery lists the newest N days while the older PNGs stay on the wall, unserved
# and unlisted, until somebody decides what to do with them.
RETAINED_PANEL_DAYS: int | None = None

# The shape of the strip a page has above the panel, and the reason it is a crop
# and not a second render: a render costs the card, and would draw a different
# picture from the one already hanging on the wall.
BANNER_ASPECT = 3.0

# The edge a gallery tile is drawn at.
THUMB_MAX_PX = 512

# A day is a full panel under exactly this name. The banner and the thumbnail are
# not days, so the match is on the whole name and not on a prefix.
_PANEL_DAY = re.compile(r"\Apanel-(\d{4}-\d{2}-\d{2})\.png\Z")


def panel_name(day: date) -> str:
    return f"panel-{day.isoformat()}.png"


def banner_name(day: date) -> str:
    return panel_name(day).removesuffix(".png") + "-banner.png"


def thumb_name(day: date) -> str:
    return panel_name(day).removesuffix(".png") + "-thumb.png"


def prompt_name(day: date) -> str:
    return panel_name(day).removesuffix(".png") + ".prompt.json"


def provenance_name(day: date) -> str:
    return panel_name(day).removesuffix(".png") + ".provenance.json"


def variant_names(day: date) -> dict[str, str]:
    """Every rendition of one day's panel, keyed by variant.

    A map keyed by the variant rather than one field per rendition, because the
    e-ink derivative is a key and not a schema change: the gallery, and anything
    reading it, takes whatever variants a day holds.
    """
    return {
        "full": panel_name(day),
        "banner": banner_name(day),
        "thumb": thumb_name(day),
    }


def existing_panel(day: date, output_dir: Path) -> Path | None:
    """The panel this run would have written, if it is already there.

    Existence is the whole test: the file is named by date, so a second run for
    a date would overwrite the only record of the first one.
    """
    candidate = output_dir / panel_name(day)
    return candidate if candidate.is_file() else None


def publish_panel(
    context: DayContext,
    caption: Caption,
    rendered: Rendered,
    payloads: dict[str, object],
    *,
    scene: Scene,
    output_dir: Path,
    report_address: str,
    published_at: datetime | None = None,
) -> Published:
    """Write the day's panel, its renditions, its two records, and the gallery."""
    _named_not_addressed(payloads)
    if not report_address.strip():
        # The obligation is on the published picture, so the check sits at the write
        # and not only at the render: a panel nobody can object to is the state the
        # model grant forbids, and it is reached as easily by a caller that forgot an
        # argument as by a configuration that never had one.
        raise ValueError(
            "report_address must name the inbox a viewer reports a suspected violation of "
            f"the model grant to; {REPORT_ADDRESS_ENV} carries it to the pipeline, and "
            "nothing is published beside the panel until it is set"
        )
    rendered_at = published_at or datetime.now(UTC)
    if rendered_at.tzinfo is None or rendered_at.utcoffset() is None:
        raise ValueError("published_at must be timezone-aware; it is what staleness is measured from")

    output_dir.mkdir(parents=True, exist_ok=True)
    staleness = Staleness(rendered_at=rendered_at, age_hours=0.0)
    panel_path = output_dir / panel_name(context.for_day)
    provenance_path = output_dir / provenance_name(context.for_day)
    # The sidecar is written first and the panel last, and every other file lands
    # between them. A panel that got there with no sidecar beside it is a picture
    # nobody can explain and nobody can report — the state the model grant forbids —
    # and the nightly cannot recover from it, because a second run for a date finds
    # the PNG and skips. Anything else that failed to be written is the failure left
    # behind instead: nothing shows, the render is still under its scratch name, and
    # the next run writes all of them again.
    _write_json(
        provenance_path,
        {
            "for_day": context.for_day.isoformat(),
            "timezone": context.timezone,
            "panel": panel_path.name,
            "renderer": rendered.renderer,
            "seed": rendered.seed,
            "width_px": rendered.width_px,
            "height_px": rendered.height_px,
            "template_hash": caption.template_hash,
            "style": caption.style,
            "caption": caption.text,
            "report_address": report_address.strip(),
            "weights": list(rendered.weights),
            "reference_photos": [str(photo) for photo in rendered.reference_photos],
            "weather": asdict(context.weather) if context.weather else None,
            "occasions": [asdict(occasion) for occasion in context.occasions],
            "weather_refusals": list(context.weather_refusals),
            "calendar_refusals": list(context.calendar_refusals),
            "payloads": payloads,
            "rendered_at": rendered_at.isoformat(),
        },
    )
    _write_json(
        output_dir / prompt_name(context.for_day),
        _prompt_record(context, caption, rendered, scene),
    )
    _write_variants(rendered.panel_path, context.for_day, output_dir)
    _write_json(
        output_dir / FRESHNESS_NAME,
        {
            "for_day": context.for_day.isoformat(),
            "panel": panel_path.name,
            "rendered_at": rendered_at.isoformat(),
            "renderer": rendered.renderer,
            "template_hash": caption.template_hash,
            "age_hours_at_write": staleness.age_hours,
        },
    )
    # Moved, not copied: the scratch name it was drawn under is a renderer
    # detail, and a published directory that keeps both is a directory where a
    # viewer has to guess which PNG is the panel.
    move(rendered.panel_path, panel_path)
    # The gallery is the one file written after the panel, because it describes the
    # directory rather than the day: it lists the days whose full panel is on the
    # volume, so today counts only once it has arrived, and a rendition left
    # behind by an interrupted run is never listed. It is rebuilt whole on every
    # publish, so a run that died between the move and here is corrected by the
    # next nightly rather than staying a day short for good.
    _write_gallery(output_dir, generated_at=rendered_at)
    return Published(
        panel_path=str(panel_path),
        provenance_path=str(provenance_path),
        for_day=context.for_day,
        staleness=staleness,
    )


def retained_days(output_dir: Path) -> tuple[date, ...]:
    """Every day the volume holds a full panel for, newest first.

    Read by the publish step, which is the only writer of the gallery. A server
    answering a request must never call this: what it would publish is the set of
    dates, which is household information and not picture information.
    """
    days = []
    for candidate in output_dir.glob("panel-*.png"):
        named = _PANEL_DAY.match(candidate.name)
        if named is None:
            continue
        try:
            days.append(date.fromisoformat(named.group(1)))
        except ValueError:
            # `panel-2026-13-45.png` is a file, not a day on the wall.
            continue
    days.sort(reverse=True)
    return tuple(days if RETAINED_PANEL_DAYS is None else days[:RETAINED_PANEL_DAYS])


def read_gallery(output_dir: Path) -> dict[str, object]:
    """The published index, as the publish step wrote it."""
    return json.loads((output_dir / GALLERY_NAME).read_text(encoding="utf-8"))


def read_freshness(output_dir: Path, *, now: datetime) -> Staleness:
    """How old the current panel is, as of `now`.

    A viewer calls this instead of trusting the picture. `rendered_at` is the
    fact; the age is derived from it at read time, so the artefact stays true
    however long it sits there.
    """
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("now must be timezone-aware to compare against a render")
    record = json.loads((output_dir / FRESHNESS_NAME).read_text(encoding="utf-8"))
    rendered_at = datetime.fromisoformat(record["rendered_at"])
    age_hours = (now - rendered_at).total_seconds() / 3600
    return Staleness(rendered_at=rendered_at, age_hours=age_hours)


def _named_not_addressed(payloads: dict[str, object]) -> None:
    """Refuse to publish a payload filed under the address it was fetched from.

    This directory is served to whoever can see the panel, and a private feed
    address carries the calendar's read token in its path. The check sits at the
    write rather than in a job that might not have run, and it counts the
    offending entries without naming them: the key is the secret.
    """
    addressed = [name for name in payloads if "://" in name]
    if addressed:
        raise ValueError(
            f"{len(addressed)} of {len(payloads)} payloads are filed under an address "
            "instead of a feed label; the addresses are not repeated here because a feed "
            "address is a credential, and this file is published beside the panel"
        )


def _prompt_record(
    context: DayContext, caption: Caption, rendered: Rendered, scene: Scene
) -> dict[str, object]:
    """The public half of what made this panel.

    The provenance sidecar is the other half and stays unserved: it carries the
    reference-photo paths, the weight paths, the feed payloads and the report
    address. This record is the curated counterpart — the prompt itself, the seed,
    the style, and what the day was — and none of its fields is a path or an
    address, which is the line between the two files and the whole reason both
    exist.
    """
    return {
        "for_day": context.for_day.isoformat(),
        "prompt": caption.text,
        "seed": rendered.seed,
        "style": caption.style,
        "activity": scene.activity,
        "weather_words": context.weather.forecast_words if context.weather else None,
        "occasion": panel_occasion(context.occasions),
    }


def _write_variants(source: Path, day: date, output_dir: Path) -> None:
    """Crop and scale the panel that was just drawn; never ask the model again.

    Each rendition is saved under a scratch name and none of them is renamed until
    all of them exist, so a thumbnail that failed to save takes the banner's bytes
    with it: a directory holding one crop and not the other is a day half published,
    and nothing later goes back for the missing half. A scratch name is what a
    failure may leave, and no page can be built from one.

    From the render's own bytes, before they take the panel's name, so a variant
    that cannot be written leaves no half-published day behind. A file Pillow
    cannot open is not a panel: the publish refuses, and the render stays under its
    scratch name where the next run will find it.
    """
    staged: list[tuple[str, Path]] = []
    renamed: list[tuple[str, Path]] = []
    published = False
    try:
        with Image.open(source) as panel:
            renditions = ((banner_name(day), _banner_crop(panel)), (thumb_name(day), _thumbnail(panel)))
            for name, image in renditions:
                scratch = output_dir / f"{name}.tmp"
                image.save(scratch, format="PNG")
                staged.append((name, scratch))
        try:
            for name, scratch in staged:
                replace(scratch, output_dir / name)
                renamed.append((name, scratch))
        except BaseException:
            # A replace that failed with an earlier one already done has half
            # published the day: the banner at its final name, the thumbnail
            # missing, and the manifest naming both. Roll the finished renames
            # back to their scratch names so the finally block below removes
            # every scratch and the directory holds no variant at all - a day
            # with no banner is what the next run corrects, not one with half
            # of one.
            for name, scratch in renamed:
                replace(output_dir / name, scratch)
            raise
        published = True
    finally:
        if not published:
            for _, scratch in staged:
                scratch.unlink(missing_ok=True)


def _banner_crop(panel: Image.Image) -> Image.Image:
    """The widest band of `BANNER_ASPECT` the panel holds, taken from its centre.

    Centred because the caption instructs the model to compose for a square crop
    and keep nothing important near the edges. The forecast plate in the lower
    corner is the one thing the band loses, and the full panel still carries it.
    """
    width, height = panel.size
    if width >= height * BANNER_ASPECT:
        band = max(1, int(height * BANNER_ASPECT))
        offset = (width - band) // 2
        return panel.crop((offset, 0, offset + band, height))
    band = max(1, int(width / BANNER_ASPECT))
    offset = (height - band) // 2
    return panel.crop((0, offset, width, offset + band))


def _thumbnail(panel: Image.Image) -> Image.Image:
    thumb = panel.copy()
    # `thumbnail` never enlarges, so a small panel is published small rather than
    # padded into a blurry version of itself.
    thumb.thumbnail((THUMB_MAX_PX, THUMB_MAX_PX), Image.Resampling.LANCZOS)
    return thumb


def _write_gallery(output_dir: Path, *, generated_at: datetime) -> None:
    _write_json(
        output_dir / GALLERY_NAME,
        {
            "generated_at": generated_at.isoformat(),
            "retained_days": RETAINED_PANEL_DAYS,
            "days": [_day_record(day, output_dir) for day in retained_days(output_dir)],
        },
    )


def _day_record(day: date, output_dir: Path) -> dict[str, object]:
    """What a page for this day can be built from: only the files that are there.

    A day published before a variant existed lists the variants it has. Naming a
    file the volume does not hold turns one interrupted nightly into a broken
    image on every page that reads the index.
    """
    variants = {
        variant: name
        for variant, name in variant_names(day).items()
        if (output_dir / name).is_file()
    }
    record: dict[str, object] = {"day": day.isoformat(), "variants": variants}
    prompt = prompt_name(day)
    if (output_dir / prompt).is_file():
        record["prompt"] = prompt
    return record


def _write_json(path: Path, record: dict[str, object]) -> None:
    text = json.dumps(record, indent=2, sort_keys=True, default=_serialisable)
    path.write_text(text + "\n", encoding="utf-8")


def _serialisable(value: object) -> str:
    # Instants round-trip through `datetime.fromisoformat`, which is what
    # `read_freshness` does to find out how old the panel is.
    return value.isoformat() if isinstance(value, datetime | date) else str(value)
