"""Stage 4: put the panel where it is read, and write down how it was made.

Three files, and the third is the one that matters most.

The panel is what the viewer sees. The provenance sidecar is what makes a wrong
picture explainable afterwards — which template, which seed, which weights,
which reference photos, and the raw payload each source actually answered with.
The freshness artefact is what makes a *stopped* pipeline visible: nothing here
keeps history, so a panel that has not been redrawn for nine days looks exactly
like one that was. The only difference a viewer can see is the timestamp beside
it, so the timestamp is published as a separate, always-current file rather
than being something a reader has to trust the PNG about.
"""

import json
from dataclasses import asdict
from datetime import UTC, date, datetime
from pathlib import Path
from shutil import move

from forecats_pipeline.contracts import Caption, DayContext, Published, Staleness
from forecats_pipeline.render_stage import Rendered

__all__ = [
    "FRESHNESS_NAME",
    "existing_panel",
    "panel_name",
    "provenance_name",
    "publish_panel",
    "read_freshness",
]

FRESHNESS_NAME = "freshness.json"


def panel_name(day: date) -> str:
    return f"panel-{day.isoformat()}.png"


def provenance_name(day: date) -> str:
    return panel_name(day).removesuffix(".png") + ".provenance.json"


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
    output_dir: Path,
    published_at: datetime | None = None,
) -> Published:
    """Write the panel, its provenance, and the freshness artefact."""
    rendered_at = published_at or datetime.now(UTC)
    if rendered_at.tzinfo is None or rendered_at.utcoffset() is None:
        raise ValueError("published_at must be timezone-aware; it is what staleness is measured from")

    output_dir.mkdir(parents=True, exist_ok=True)
    # The render is moved, not copied: the scratch name it was drawn under is
    # a renderer detail, and a published directory that keeps both is a
    # directory where a viewer has to guess which PNG is the panel.
    panel_path = output_dir / panel_name(context.for_day)
    move(rendered.panel_path, panel_path)

    staleness = Staleness(rendered_at=rendered_at, age_hours=0.0)
    provenance_path = output_dir / provenance_name(context.for_day)
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
    return Published(
        panel_path=str(panel_path),
        provenance_path=str(provenance_path),
        for_day=context.for_day,
        staleness=staleness,
    )


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


def _write_json(path: Path, record: dict[str, object]) -> None:
    text = json.dumps(record, indent=2, sort_keys=True, default=_serialisable)
    path.write_text(text + "\n", encoding="utf-8")


def _serialisable(value: object) -> str:
    # Instants round-trip through `datetime.fromisoformat`, which is what
    # `read_freshness` does to find out how old the panel is.
    return value.isoformat() if isinstance(value, datetime | date) else str(value)
